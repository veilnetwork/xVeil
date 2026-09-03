import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/cloud.dart';
import '../../domain/cloud_capability.dart';
import '../../domain/public_directory_pointer.dart';
import '../../routing/back_affordance.dart';
import '../../state/public_directory_providers.dart';
import '../../state/public_directory_service.dart';
import '../../domain/chat.dart';
import '../../domain/cloud_collection_crdt.dart';
import '../../domain/cloud_document.dart';
import '../../domain/cloud_document_replication.dart';
import '../../domain/cloud_rich_text_crdt.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_capability_service.dart';
import '../../state/cloud_document_providers.dart';
import '../../state/cloud_document_replication_service.dart';
import '../../state/cloud_service.dart';
import 'cloud_collection_editor.dart';
import 'cloud_item_actions.dart';
import 'cloud_note_editor.dart';
import 'cloud_shared_document_editor.dart';

/// Personal-cloud surface. The signed device-group log owns the logical index;
/// this screen only selects local replication policy and asks the service to
/// import/fetch/verify immutable content-addressed bytes.
class CloudStorageScreen extends ConsumerStatefulWidget {
  const CloudStorageScreen({super.key});

  @override
  ConsumerState<CloudStorageScreen> createState() => _CloudStorageScreenState();
}

/// Session-only document ordering. Folders always list first, name-sorted.
enum _CloudSortMode { name, date, size }

/// Everything the cloud root's overflow menu can do. Sorting shares the menu
/// with the actions rather than owning a second button: it is the one thing
/// here with a current value, and a checkmark shows it without a tooltip.
enum _CloudMenu {
  sortName,
  sortDate,
  sortSize,
  trash,
  usage,
  verify,
  importLink,
  folderSync,
  settings,
}

class _CloudStorageScreenState extends ConsumerState<CloudStorageScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Restore any published public directory so the folder menu can offer
    // "unpublish" for the right folder (start is idempotent + republishes).
    final directory = ref.read(publicDirectoryServiceProvider);
    if (directory != null) {
      unawaited(
        directory.start().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  /// The flat folder currently open; null renders the root. If the folder is
  /// tombstoned by another device the view falls back to the root on its own
  /// (the id simply stops resolving to a live folder).
  String? _openFolderId;

  /// Search is a view-only filter over the current level and everything
  /// below it; matches render as one flat list with their folder path.
  bool _searching = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  _CloudSortMode _sort = _CloudSortMode.date;

  /// Multi-select over documents (never folders). Entered by long-press,
  /// left through the AppBar close button or system back.
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  CloudService? get _service => ref.read(cloudServiceProvider);
  CloudCapabilityService? get _capabilityService =>
      ref.read(cloudCapabilityServiceProvider);
  CloudDocumentReplicationService? get _documentService =>
      ref.read(cloudDocumentReplicationServiceProvider);
  PublicDirectoryService? get _publicDirectory =>
      ref.read(publicDirectoryServiceProvider);

  Future<void> _importFile() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    try {
      // Cancelling the picker is not an import and not a failure; it says
      // nothing.
      final imported = await importPickedCloudFile(
        service,
        folderId: _openFolderId,
      );
      if (mounted && imported != null) {
        _notice(AppL10n.of(context).cloudImported);
      }
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudImportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createNote() async {
    final service = _service;
    if (service == null || _busy) return;
    await Navigator.push<CloudItem>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            CloudNoteEditorScreen(service: service, folderId: _openFolderId),
      ),
    );
  }

  Future<void> _showAddMenu() async {
    if (_service == null || _busy) return;
    final l = AppL10n.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(l.cloudAddNote),
              onTap: () => Navigator.pop(context, 'note'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(l.cloudAddFile),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(l.cloudNewFolder),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
            if (_capabilityService != null)
              ListTile(
                leading: const Icon(Icons.folder_shared_outlined),
                title: Text(l.cloudFolderOpen),
                onTap: () => Navigator.pop(context, 'openFolder'),
              ),
            if (_publicDirectory != null)
              ListTile(
                leading: const Icon(Icons.travel_explore_outlined),
                title: Text(l.cloudPublicDirOpen),
                onTap: () => Navigator.pop(context, 'openPublicDir'),
              ),
            if (_documentService?.canMutate == true)
              ListTile(
                leading: const Icon(Icons.group_add_outlined),
                title: Text(l.cloudSharedNew),
                onTap: () => Navigator.pop(context, 'shared'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'note') await _createNote();
    if (action == 'file') await _importFile();
    if (action == 'folder') await _createFolder();
    if (action == 'openFolder') await _openFolderLink();
    if (action == 'openPublicDir') await _openPublicDirectory();
    if (action == 'shared') await _createSharedDocument();
  }

  Future<String?> _promptFolderName({
    required String title,
    required String confirmLabel,
    String? initial,
  }) => showDialog<String>(
    context: context,
    builder: (context) => _FolderNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
    ),
  );

  Future<void> _createFolder() async {
    final service = _service;
    if (service == null) return;
    final l = AppL10n.of(context);
    final name = await _promptFolderName(
      title: l.cloudNewFolder,
      confirmLabel: l.cloudFolderCreate,
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await service.createFolder(name, parentId: _openFolderId);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudFolderFailed);
    }
  }

  /// Depth-first flattening of the live folder tree for destination pickers:
  /// (folder, depth) rows in display order, minus [excludeSubtreeOf] and its
  /// descendants (a folder can never move into itself).
  List<({CloudFolder folder, int depth})> _folderTreeRows({
    String? excludeSubtreeOf,
  }) {
    final service = _service;
    if (service == null) return const [];
    final tree = service.folderChildrenIndex();
    final rows = <({CloudFolder folder, int depth})>[];
    void walk(String? parentId, int depth) {
      if (depth > 32) return;
      for (final folder in tree[parentId] ?? const <CloudFolder>[]) {
        if (folder.id == excludeSubtreeOf) continue;
        rows.add((folder: folder, depth: depth));
        walk(folder.id, depth + 1);
      }
    }

    walk(null, 0);
    return rows;
  }

  Future<void> _moveFolder(CloudFolder folder) async {
    final service = _service;
    if (service == null) return;
    final l = AppL10n.of(context);
    final rows = _folderTreeRows(excludeSubtreeOf: folder.id);
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(l.cloudMoveFolder)),
              ListTile(
                key: const ValueKey('cloud-folder-move-root'),
                leading: const Icon(Icons.home_outlined),
                title: Text(l.cloudStorageRoot),
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final row in rows)
                ListTile(
                  key: ValueKey('cloud-folder-move-${row.folder.id}'),
                  leading: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 16.0 * row.depth,
                    ),
                    child: const Icon(Icons.folder_outlined),
                  ),
                  title: Text(
                    row.folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, row.folder.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    try {
      await service.moveFolder(folder.id, target.isEmpty ? null : target);
      if (mounted) _notice(l.cloudFolderMoved);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudFolderFailed);
    }
  }

  Future<void> _renameFolder(CloudFolder folder) async {
    final service = _service;
    if (service == null) return;
    final l = AppL10n.of(context);
    final name = await _promptFolderName(
      title: l.cloudFolderRename,
      confirmLabel: l.cloudFolderRename,
      initial: folder.name,
    );
    if (name == null || name.isEmpty || name == folder.name || !mounted) {
      return;
    }
    try {
      await service.renameFolder(folder.id, name);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudFolderFailed);
    }
  }

  Future<void> _shareFolder(CloudFolder folder) async {
    final cloud = _service;
    final capabilities = _capabilityService;
    if (cloud == null || capabilities == null || _busy) return;
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      final existing = capabilities
          .listFolderShares()
          .where((share) => share.folderId == folder.id)
          .firstOrNull;
      if (existing != null) {
        if (!mounted) return;
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.cloudFolderShareExisting),
            content: SelectableText(existing.link, maxLines: 5),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'revoke'),
                child: Text(l.cloudFolderShareRevoke),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'refresh'),
                child: Text(l.cloudFolderShareRefresh),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'copy'),
                child: Text(l.cloudPublicCopy),
              ),
            ],
          ),
        );
        if (action == 'revoke') {
          await capabilities.revokeFolderShare(existing.shareId);
          if (mounted) _notice(l.cloudFolderShareRevoked);
        } else if (action == 'refresh') {
          final entries = await cloud.buildFolderListingEntries(folder.id);
          if (entries != null) {
            await capabilities.refreshFolderShare(
              existing.shareId,
              folderName: folder.name,
              entries: entries,
            );
          }
          if (mounted) _notice(l.cloudFolderShareRefreshed);
        } else if (action == 'copy') {
          await Clipboard.setData(ClipboardData(text: existing.link));
          if (mounted) _notice(l.cloudPublicCopied);
        }
        return;
      }
      final entries = await cloud.buildFolderListingEntries(folder.id);
      if (entries == null || entries.isEmpty) {
        if (mounted) _notice(l.cloudFolderShareEmpty);
        return;
      }
      final share = await capabilities.createFolderShare(
        folderId: folder.id,
        folderName: folder.name,
        entries: entries,
      );
      await Clipboard.setData(ClipboardData(text: share.link));
      if (mounted) _notice(l.cloudFolderShareCreated);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudFolderShareFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Bind a folder to this identity's nickname as a PUBLIC directory. Warns
  /// first: this is the opposite of an anonymous bearer link — anyone who
  /// knows the nickname sees the folder and that it belongs to this identity.
  Future<void> _publishFolderPublic(CloudFolder folder) async {
    final cloud = _service;
    final capabilities = _capabilityService;
    final directory = _publicDirectory;
    if (cloud == null || capabilities == null || directory == null || _busy) {
      return;
    }
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudPublicDirPublish),
        content: Text(l.cloudPublicDirWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudPublicDirConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final entries = await cloud.buildFolderListingEntries(folder.id);
      if (entries == null || entries.isEmpty) {
        if (mounted) _notice(l.cloudFolderShareEmpty);
        return;
      }
      await directory.start();
      final share = await capabilities.createFolderShare(
        folderId: folder.id,
        folderName: folder.name,
        entries: entries,
      );
      // The service revokes any prior directory's share on success; we only
      // clean up THIS share if publishing failed.
      final ok = await directory.publish(
        folderId: folder.id,
        shareId: share.shareId,
        link: share.link,
        title: folder.name,
      );
      if (!ok) {
        await capabilities.revokeFolderShare(share.shareId);
        if (mounted) _notice(l.cloudPublicDirFailed);
        return;
      }
      if (mounted) _notice(l.cloudPublicDirPublished);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudPublicDirFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Stop publishing this identity's public directory: withdraw the pointer
  /// (it stops being republished and expires) and revoke the folder share so
  /// it no longer serves bytes.
  Future<void> _unpublishDirectory() async {
    final directory = _publicDirectory;
    if (directory == null || _busy) return;
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      await directory.start();
      await directory.withdraw();
      if (mounted) _notice(l.cloudPublicDirUnpublished);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudPublicDirFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Open someone's public directory by their nickname: resolve → verify →
  /// browse the folder with the ordinary received-folder screen.
  Future<void> _openPublicDirectory() async {
    final directory = _publicDirectory;
    final capabilities = _capabilityService;
    final cloud = _service;
    if (directory == null || capabilities == null || cloud == null) return;
    final l = AppL10n.of(context);
    final nickname = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: l.cloudPublicDirOpen,
        confirmLabel: l.cloudPublicDirResolve,
        hint: l.cloudPublicDirNicknameHint,
        prefixText: '@',
      ),
    );
    if (!mounted || nickname == null || nickname.isEmpty) return;
    setState(() => _busy = true);
    PublicDirectoryPointer? pointer;
    try {
      pointer = await directory.resolveByNickname(nickname);
    } catch (_) {
      pointer = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (pointer == null) {
      _notice(l.cloudPublicDirNotFound);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => CloudReceivedFolderScreen(
          capabilities: capabilities,
          cloud: cloud,
          link: pointer!.link,
        ),
      ),
    );
  }

  Future<void> _openFolderLink() async {
    final capabilities = _capabilityService;
    final cloud = _service;
    if (capabilities == null || cloud == null) return;
    final l = AppL10n.of(context);
    final link = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: l.cloudFolderOpen,
        confirmLabel: l.cloudDownload,
        hint: l.cloudFolderOpenHint,
        minLines: 2,
        maxLines: 5,
      ),
    );
    if (!mounted || link == null || link.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => CloudReceivedFolderScreen(
          capabilities: capabilities,
          cloud: cloud,
          link: link,
        ),
      ),
    );
  }

  Future<void> _deleteFolder(CloudFolder folder) async {
    final service = _service;
    if (service == null) return;
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudFolderDeleteTitle(folder.name)),
        content: Text(l.cloudFolderDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudFolderDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // Deleting the folder that is currently published as a public directory
      // must also stop publishing + revoke its share — otherwise it would keep
      // serving bytes for a folder the user just deleted.
      //
      // Asked and answered in ONE queued step. Reading `status` here and then
      // deciding was a race against the service's own restore: this screen
      // lists folders as soon as the listing arrives, which can be well
      // before the saved pointer has been read back, and an empty status then
      // said "nothing published" for a folder that was. The delete went
      // through, the late restore republished the pointer, and the bearer
      // share kept serving for its seven days.
      await _publicDirectory?.withdrawIfFolder(folder.id);
      final fallback = service.effectiveFolderParents()[folder.id];
      await service.deleteFolder(folder.id);
      if (mounted && _openFolderId == folder.id) {
        setState(() => _openFolderId = fallback);
      }
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudFolderFailed);
    }
  }

  Future<NodeId?> _pickAcceptedContact(
    List<Contact> contacts, {
    Set<String> excluded = const {},
  }) async {
    final available = contacts
        .where((contact) => !excluded.contains(contact.nodeId.hex))
        .toList();
    if (available.isEmpty) {
      _notice(AppL10n.of(context).cloudNoContacts);
      return null;
    }
    final l = AppL10n.of(context);
    return showModalBottomSheet<NodeId>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: available.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(title: Text(l.cloudSharedPickContact));
              }
              final contact = available[index - 1];
              return ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: Text(contact.label),
                subtitle: Text(contact.nodeId.short),
                onTap: () => Navigator.pop(context, contact.nodeId),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<CloudDocumentRole?> _pickDocumentRole() {
    final l = AppL10n.of(context);
    return showDialog<CloudDocumentRole>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.cloudSharedRole),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentRole.editor),
            child: Text(l.cloudSharedRoleEditor),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentRole.viewer),
            child: Text(l.cloudSharedRoleViewer),
          ),
        ],
      ),
    );
  }

  Future<CloudDocumentKind?> _pickDocumentKind() {
    final l = AppL10n.of(context);
    return showDialog<CloudDocumentKind>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.cloudSharedPickKind),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentKind.note),
            child: ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: Text(l.cloudKindNote),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentKind.taskList),
            child: ListTile(
              leading: const Icon(Icons.task_alt_outlined),
              title: Text(l.cloudKindTasks),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentKind.calendar),
            child: ListTile(
              leading: const Icon(Icons.calendar_month_outlined),
              title: Text(l.cloudKindCalendar),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createSharedDocument() async {
    final documents = _documentService;
    final cloud = _service;
    if (documents == null || cloud == null || _busy) return;
    final kind = await _pickDocumentKind();
    if (kind == null || !mounted) return;
    final peer = await _pickAcceptedContact(await cloud.acceptedContacts());
    if (peer == null || !mounted) return;
    final role = await _pickDocumentRole();
    if (role == null || !mounted) return;
    setState(() => _busy = true);
    CloudDocumentMutationResult? result;
    try {
      final codec = switch (kind) {
        CloudDocumentKind.note => cloudRichTextCodecV1,
        CloudDocumentKind.taskList => cloudTaskListCodecV1,
        CloudDocumentKind.calendar => cloudCalendarCodecV1,
        CloudDocumentKind.fileCollection => cloudFileCollectionCodecV1,
      };
      final created = await documents.createDocument(kind: kind, codec: codec);
      if (created != null) {
        result = await documents.grant(created.documentId, peer, role);
      }
    } catch (_) {
      result = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final l = AppL10n.of(context);
    _notice(
      result == null
          ? l.cloudSharedFailed
          : result.fullyQueued
          ? l.cloudSharedCreated
          : l.cloudSharedPartial,
    );
  }

  Future<void> _verifyAll() async {
    final service = _service;
    if (service == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await service.verifyAll(repair: true);
      if (!mounted) return;
      final damaged = result.values.where((ok) => !ok).length;
      _notice(
        damaged == 0
            ? AppL10n.of(context).cloudVerifyOk
            : AppL10n.of(context).cloudRepairStarted(damaged),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPublicLink() async {
    final cloud = _service;
    final capabilities = _capabilityService;
    if (cloud == null || capabilities == null || _busy) return;
    final l = AppL10n.of(context);
    final link = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: l.cloudPublicImport,
        confirmLabel: l.cloudDownload,
        hint: l.cloudPublicPasteHint,
        minLines: 2,
        maxLines: 5,
      ),
    );
    if (!mounted || link == null || link.isEmpty) return;
    setState(() => _busy = true);
    try {
      final capability = await capabilities.download(link);
      await cloud.adoptCapability(capability);
      if (mounted) _notice(l.cloudImported);
    } catch (_) {
      if (mounted) _notice(l.cloudPublicOpenFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _startSearch() => setState(() => _searching = true);

  /// What the cloud costs. Everything shown is folded from state that already
  /// replicates, including the per-device rows — a replica claim carries its
  /// size — so opening this asks nothing of the network.
  /// The undo buffer for deletions on this device.
  ///
  /// A dialog rather than a route: the trash is somewhere you go to take one
  /// action and leave, and its whole content is a short list. The list is
  /// rebuilt from the service after every action, so it never shows a row the
  /// service has already released.
  /// A menu row that names what it does. `ListTile` inside the item rather
  /// than a bare `Text` so the icon travels WITH its label — the icons were
  /// never the problem, being alone was.
  PopupMenuItem<_CloudMenu> _menuItem(
    _CloudMenu value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) => PopupMenuItem<_CloudMenu>(
    key: ValueKey('cloud-${value.name}'),
    value: value,
    enabled: enabled,
    child: ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
    ),
  );

  void _onMenuSelected(_CloudMenu item) {
    switch (item) {
      case _CloudMenu.sortName:
        setState(() => _sort = _CloudSortMode.name);
      case _CloudMenu.sortDate:
        setState(() => _sort = _CloudSortMode.date);
      case _CloudMenu.sortSize:
        setState(() => _sort = _CloudSortMode.size);
      case _CloudMenu.trash:
        _showTrash();
      case _CloudMenu.usage:
        _showUsage();
      case _CloudMenu.verify:
        _verifyAll();
      case _CloudMenu.importLink:
        _importPublicLink();
      case _CloudMenu.folderSync:
        context.push('/storage/folder-sync');
      case _CloudMenu.settings:
        _showCloudSettings();
    }
  }

  /// Cloud settings, which is where a setting belongs.
  ///
  /// "Keep on this device" used to sit above the file list on every visit: a
  /// three-line explanation of a replication mode, permanently occupying the
  /// space where the files are, for a choice made once. Someone opening their
  /// cloud is looking for a file, not for a storage policy.
  Future<void> _showCloudSettings() async {
    final service = ref.read(cloudServiceProvider);
    if (service == null) return;
    final l = AppL10n.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                l.cloudSettings,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            _ReplicationProfile(service: service),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrash() async {
    final service = ref.read(cloudServiceProvider);
    if (service == null) return;
    var entries = await service.trashedItems();
    if (!mounted) return;
    final l = AppL10n.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const ValueKey('cloud-trash-dialog'),
          title: Text(l.cloudTrash),
          content: SizedBox(
            width: 420,
            child: entries.isEmpty
                ? Text(l.cloudTrashEmptyState)
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.cloudTrashHint,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        for (final entry in entries)
                          ListTile(
                            key: ValueKey('cloud-trash-${entry.item.id}'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(entry.item.name),
                            subtitle: Text(formatCloudBytes(entry.item.size)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  key: ValueKey(
                                    'cloud-trash-restore-${entry.item.id}',
                                  ),
                                  onPressed: () async {
                                    final name = entry.item.name;
                                    await service.restoreItem(entry.item.id);
                                    entries = await service.trashedItems();
                                    if (!context.mounted) return;
                                    setDialogState(() {});
                                    _notice(l.cloudTrashRestored(name));
                                  },
                                  child: Text(l.cloudTrashRestore),
                                ),
                                IconButton(
                                  key: ValueKey(
                                    'cloud-trash-purge-${entry.item.id}',
                                  ),
                                  tooltip: l.cloudTrashDeleteForever,
                                  onPressed: () async {
                                    await service.purgeItem(entry.item.id);
                                    entries = await service.trashedItems();
                                    if (!context.mounted) return;
                                    setDialogState(() {});
                                  },
                                  icon: const Icon(Icons.delete_forever),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            if (entries.isNotEmpty)
              TextButton(
                key: const ValueKey('cloud-trash-empty'),
                onPressed: () async {
                  await service.emptyTrash();
                  entries = await service.trashedItems();
                  if (!context.mounted) return;
                  setDialogState(() {});
                  _notice(l.cloudTrashEmptied);
                },
                child: Text(l.cloudTrashEmptyAction),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.actionDone),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showUsage() async {
    final service = ref.read(cloudServiceProvider);
    if (service == null) return;
    final usage = await service.usage();
    if (!mounted) return;
    final l = AppL10n.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('cloud-usage-dialog'),
        title: Text(l.cloudUsage),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l.cloudUsageOnThisDevice),
                subtitle: Text(l.cloudUsageItems(usage.localItems)),
                trailing: Text(formatCloudBytes(usage.localBytes)),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l.cloudUsageInCloud),
                subtitle: Text(l.cloudUsageItems(usage.logicalItems)),
                trailing: Text(formatCloudBytes(usage.logicalBytes)),
              ),
              Text(
                l.cloudUsageNotHeldHere(usage.indexOnlyItems),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (usage.devices.isNotEmpty) ...[
                const Divider(),
                Text(
                  l.cloudUsageByDevice,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final device in usage.devices)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      device.isSelf
                          ? '${device.deviceId.short} · ${l.cloudUsageThisDevice}'
                          : device.deviceId.short,
                    ),
                    subtitle: Text(l.cloudUsageItems(device.items)),
                    trailing: Text(formatCloudBytes(device.bytes)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.actionDone),
          ),
        ],
      ),
    );
  }

  void _stopSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  void _enterSelection(String itemId) {
    setState(() {
      _selecting = true;
      _selectedIds.add(itemId);
    });
  }

  void _toggleSelection(String itemId) {
    setState(() {
      if (!_selectedIds.add(itemId)) _selectedIds.remove(itemId);
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  /// Destination picker shared by the bulk move action: '' means the root,
  /// null means the sheet was dismissed.
  Future<String?> _pickBulkTarget() {
    final l = AppL10n.of(context);
    final rows = _folderTreeRows();
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(l.cloudMoveToFolder)),
              ListTile(
                key: const ValueKey('cloud-bulk-move-root'),
                leading: const Icon(Icons.home_outlined),
                title: Text(l.cloudMoveToRoot),
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final row in rows)
                ListTile(
                  key: ValueKey('cloud-bulk-move-${row.folder.id}'),
                  leading: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 16.0 * row.depth,
                    ),
                    child: const Icon(Icons.folder_outlined),
                  ),
                  title: Text(
                    row.folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, row.folder.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _bulkMove() async {
    final service = _service;
    if (service == null || _selectedIds.isEmpty) return;
    final l = AppL10n.of(context);
    final target = await _pickBulkTarget();
    if (target == null || !mounted) return;
    var failures = 0;
    for (final id in List.of(_selectedIds)) {
      try {
        await service.moveItemToFolder(id, target.isEmpty ? null : target);
      } catch (_) {
        failures++;
      }
    }
    if (!mounted) return;
    _exitSelection();
    _notice(failures == 0 ? l.cloudFolderMoved : l.cloudFolderFailed);
  }

  Future<void> _bulkDelete() async {
    final service = _service;
    if (service == null || _selectedIds.isEmpty) return;
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudBulkDeleteTitle(_selectedIds.length)),
        content: Text(l.cloudDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final id in List.of(_selectedIds)) {
      try {
        await service.deleteItem(id);
      } catch (_) {}
    }
    if (mounted) _exitSelection();
  }

  void _sortDocuments(List<CloudItem> documents) {
    switch (_sort) {
      case _CloudSortMode.name:
        documents.sort((a, b) {
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return byName != 0
              ? byName
              : b.modifiedAtMs.compareTo(a.modifiedAtMs);
        });
      case _CloudSortMode.date:
        documents.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
      case _CloudSortMode.size:
        documents.sort((a, b) {
          final bySize = b.size.compareTo(a.size);
          return bySize != 0
              ? bySize
              : b.modifiedAtMs.compareTo(a.modifiedAtMs);
        });
    }
  }

  /// Human-readable folder chain for a search result, rooted at the storage
  /// root label.
  String _pathLabel(CloudService service, String? folderId) {
    final l = AppL10n.of(context);
    if (folderId == null) return l.cloudStorageRoot;
    final path = service
        .folderPath(folderId)
        .map((folder) => folder.name)
        .join(' / ');
    return path.isEmpty ? l.cloudStorageRoot : '${l.cloudStorageRoot} / $path';
  }

  /// Flat search results over the subtree rooted at the open folder: every
  /// matching live folder and document below (and at) the current level.
  Widget _searchResults(
    CloudService service,
    List<CloudItem> rows,
    String query,
  ) {
    final l = AppL10n.of(context);
    final tree = service.folderChildrenIndex();
    final parents = service.effectiveFolderParents();
    final rootId = _openFolderId != null && parents.containsKey(_openFolderId)
        ? _openFolderId
        : null;
    final scopeIds = <String?>{rootId};
    final matchedFolders = <CloudFolder>[];
    void walk(String? parentId, int depth) {
      if (depth > 32) return;
      for (final folder in tree[parentId] ?? const <CloudFolder>[]) {
        scopeIds.add(folder.id);
        if (folder.name.toLowerCase().contains(query)) {
          matchedFolders.add(folder);
        }
        walk(folder.id, depth + 1);
      }
    }

    walk(rootId, 0);
    final matchedDocuments = [
      for (final item in rows)
        if (scopeIds.contains(service.effectiveFolderId(item)) &&
            item.name.toLowerCase().contains(query))
          item,
    ];
    _sortDocuments(matchedDocuments);
    if (matchedFolders.isEmpty && matchedDocuments.isEmpty) {
      return Center(child: Text(l.cloudSearchEmpty));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: matchedFolders.length + matchedDocuments.length,
      itemBuilder: (context, index) {
        if (index < matchedFolders.length) {
          final folder = matchedFolders[index];
          return ListTile(
            key: ValueKey('cloud-search-folder-${folder.id}'),
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_pathLabel(service, parents[folder.id])),
            onTap: () {
              _stopSearch();
              setState(() => _openFolderId = folder.id);
            },
          );
        }
        final item = matchedDocuments[index - matchedFolders.length];
        return _CloudItemTile(
          key: ValueKey('${item.id}:${item.revision}'),
          item: item,
          service: service,
          capabilityService: ref.watch(cloudCapabilityServiceProvider),
          pathLabel: _pathLabel(service, service.effectiveFolderId(item)),
          selectionMode: _selecting,
          selected: _selectedIds.contains(item.id),
          onToggleSelection: () => _toggleSelection(item.id),
          onEnterSelection: () => _enterSelection(item.id),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(cloudServiceProvider);
    final items = ref.watch(cloudItemsProvider);
    final folders =
        ref.watch(cloudFoldersProvider).asData?.value ?? const <CloudFolder>[];
    final openFolder = folders
        .where((folder) => folder.id == _openFolderId)
        .firstOrNull;
    final documentService = ref.watch(cloudDocumentReplicationServiceProvider);
    void goUp() {
      if (openFolder == null) return;
      setState(
        () => _openFolderId = service?.effectiveFolderParents()[openFolder.id],
      );
    }

    return PopScope(
      canPop: openFolder == null && !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelection();
        } else if (_searching) {
          _stopSearch();
        } else {
          goUp();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  key: const ValueKey('cloud-selection-close'),
                  tooltip: l.actionCancel,
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close),
                )
              : openFolder == null
              // At the cloud ROOT there is no folder to go up to, so back has
              // to leave the screen. Leaving this null fell back to the
              // automatic leading, which the flat router only renders when
              // something sits below — entered with an empty stack the cloud
              // was a dead end.
              ? const RootedBackButton()
              : BackButton(onPressed: goUp),
          title: _selecting
              ? Text(l.cloudSelectedCount(_selectedIds.length))
              : _searching
              ? TextField(
                  key: const ValueKey('cloud-search-field'),
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l.cloudSearchHint,
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                )
              : Text(openFolder?.name ?? l.cloudTitle),
          actions: [
            if (_selecting) ...[
              IconButton(
                key: const ValueKey('cloud-bulk-move'),
                tooltip: l.cloudMoveToFolder,
                onPressed: service == null ? null : _bulkMove,
                icon: const Icon(Icons.drive_file_move_outlined),
              ),
              IconButton(
                key: const ValueKey('cloud-bulk-delete'),
                tooltip: l.cloudDelete,
                onPressed: service == null ? null : _bulkDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ] else if (_searching)
              IconButton(
                key: const ValueKey('cloud-search-close'),
                tooltip: l.actionCancel,
                onPressed: _stopSearch,
                icon: const Icon(Icons.close),
              )
            else ...[
              IconButton(
                key: const ValueKey('cloud-search'),
                tooltip: l.cloudSearch,
                onPressed: service == null ? null : _startSearch,
                icon: const Icon(Icons.search),
              ),
              // One menu with written names, where there used to be seven
              // icon-only buttons. Seven 48dp targets plus a back button leave
              // a phone's app bar with room for roughly one character of the
              // folder name — the title rendered as "Л…" — and a row of bare
              // glyphs is legible only to someone who already knows what each
              // one does. A tooltip is not an answer: it needs a long-press
              // nobody performs, and on the way to the wrong icon.
              PopupMenuButton<_CloudMenu>(
                key: const ValueKey('cloud-menu'),
                icon: const Icon(Icons.more_vert),
                onSelected: _onMenuSelected,
                itemBuilder: (context) => [
                  PopupMenuItem<_CloudMenu>(
                    enabled: false,
                    height: 34,
                    child: Text(
                      l.cloudSort,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  CheckedPopupMenuItem(
                    key: const ValueKey('cloud-sort-name'),
                    value: _CloudMenu.sortName,
                    checked: _sort == _CloudSortMode.name,
                    child: Text(l.cloudSortByName),
                  ),
                  CheckedPopupMenuItem(
                    key: const ValueKey('cloud-sort-date'),
                    value: _CloudMenu.sortDate,
                    checked: _sort == _CloudSortMode.date,
                    child: Text(l.cloudSortByDate),
                  ),
                  CheckedPopupMenuItem(
                    key: const ValueKey('cloud-sort-size'),
                    value: _CloudMenu.sortSize,
                    checked: _sort == _CloudSortMode.size,
                    child: Text(l.cloudSortBySize),
                  ),
                  const PopupMenuDivider(),
                  _menuItem(
                    _CloudMenu.trash,
                    Icons.delete_outline,
                    l.cloudTrash,
                    enabled: service != null,
                  ),
                  _menuItem(
                    _CloudMenu.usage,
                    Icons.data_usage_outlined,
                    l.cloudUsage,
                    enabled: service != null,
                  ),
                  _menuItem(
                    _CloudMenu.verify,
                    Icons.health_and_safety_outlined,
                    l.cloudVerify,
                    enabled: service != null && !_busy,
                  ),
                  if (ref.watch(cloudCapabilityServiceProvider) != null)
                    _menuItem(
                      _CloudMenu.importLink,
                      Icons.link,
                      l.cloudPublicImport,
                      enabled: !_busy,
                    ),
                  // Desktop only: a phone has no folder to mirror that another
                  // app can also write to, and the picker returns nothing.
                  if (Platform.isMacOS ||
                      Platform.isLinux ||
                      Platform.isWindows)
                    _menuItem(
                      _CloudMenu.folderSync,
                      Icons.sync_outlined,
                      l.folderSyncTitle,
                    ),
                  const PopupMenuDivider(),
                  _menuItem(
                    _CloudMenu.settings,
                    Icons.settings_outlined,
                    l.cloudSettings,
                    enabled: service != null,
                  ),
                ],
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
        body: service == null
            ? Center(child: Text(l.cloudUnavailable))
            : Column(
                children: [
                  if (openFolder == null && documentService != null)
                    _PendingDocumentInvites(service: documentService),
                  if (openFolder == null && documentService != null)
                    _SharedDocumentSection(
                      service: documentService,
                      cloud: service,
                    ),
                  // "Keep on this device" now lives in cloud settings: it is a
                  // once-made choice, and it was standing where the files go.
                  if (openFolder != null)
                    SizedBox(
                      height: 40,
                      child: ListView(
                        key: const ValueKey('cloud-breadcrumbs'),
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          TextButton(
                            onPressed: () =>
                                setState(() => _openFolderId = null),
                            child: Text(l.cloudStorageRoot),
                          ),
                          for (final crumb in service.folderPath(
                            openFolder.id,
                          )) ...[
                            const Center(
                              child: Icon(Icons.chevron_right, size: 16),
                            ),
                            TextButton(
                              onPressed: crumb.id == openFolder.id
                                  ? null
                                  : () => setState(
                                      () => _openFolderId = crumb.id,
                                    ),
                              child: Text(
                                crumb.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: items.when(
                      data: (rows) {
                        final query = _searching
                            ? _query.trim().toLowerCase()
                            : '';
                        if (query.isNotEmpty) {
                          return _searchResults(service, rows, query);
                        }
                        // A dangling folderId (folder deleted elsewhere) resolves
                        // to the root here — documents are never hidden.
                        final visible = [
                          for (final item in rows)
                            if (service.effectiveFolderId(item) ==
                                openFolder?.id)
                              item,
                        ];
                        _sortDocuments(visible);
                        final counts = <String, int>{};
                        for (final item in rows) {
                          final effective = service.effectiveFolderId(item);
                          if (effective != null) {
                            counts[effective] = (counts[effective] ?? 0) + 1;
                          }
                        }
                        final shownFolders = service.childFolders(
                          openFolder?.id,
                        );
                        if (shownFolders.isEmpty && visible.isEmpty) {
                          return _EmptyCloud(
                            title: openFolder == null
                                ? null
                                : l.cloudFolderEmpty,
                            hint: openFolder == null
                                ? null
                                : l.cloudFolderEmptyHint,
                            onImport: _busy ? null : _importFile,
                            onNote: _busy ? null : _createNote,
                          );
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: shownFolders.length + visible.length,
                          itemBuilder: (context, index) {
                            if (index < shownFolders.length) {
                              final folder = shownFolders[index];
                              return ListTile(
                                key: ValueKey('cloud-folder-${folder.id}'),
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(
                                  folder.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  l.cloudFolderItems(counts[folder.id] ?? 0),
                                ),
                                onTap: () =>
                                    setState(() => _openFolderId = folder.id),
                                trailing: PopupMenuButton<String>(
                                  key: ValueKey(
                                    'cloud-folder-menu-${folder.id}',
                                  ),
                                  onSelected: (action) {
                                    switch (action) {
                                      case 'rename':
                                        unawaited(_renameFolder(folder));
                                      case 'moveFolder':
                                        unawaited(_moveFolder(folder));
                                      case 'share':
                                        unawaited(_shareFolder(folder));
                                      case 'publishPublic':
                                        unawaited(_publishFolderPublic(folder));
                                      case 'unpublishPublic':
                                        unawaited(_unpublishDirectory());
                                      case 'delete':
                                        unawaited(_deleteFolder(folder));
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: 'rename',
                                      child: Text(l.cloudFolderRename),
                                    ),
                                    PopupMenuItem(
                                      value: 'moveFolder',
                                      child: Text(l.cloudMoveFolder),
                                    ),
                                    if (_capabilityService != null)
                                      PopupMenuItem(
                                        value: 'share',
                                        child: Text(l.cloudFolderShare),
                                      ),
                                    if (_publicDirectory != null &&
                                        _publicDirectory!.status.folderId !=
                                            folder.id)
                                      PopupMenuItem(
                                        value: 'publishPublic',
                                        child: Text(l.cloudPublicDirPublish),
                                      ),
                                    if (_publicDirectory?.status.folderId ==
                                        folder.id)
                                      PopupMenuItem(
                                        value: 'unpublishPublic',
                                        child: Text(l.cloudPublicDirUnpublish),
                                      ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text(l.cloudFolderDelete),
                                    ),
                                  ],
                                ),
                              );
                            }
                            final item = visible[index - shownFolders.length];
                            return _CloudItemTile(
                              key: ValueKey('${item.id}:${item.revision}'),
                              item: item,
                              service: service,
                              capabilityService: ref.watch(
                                cloudCapabilityServiceProvider,
                              ),
                              selectionMode: _selecting,
                              selected: _selectedIds.contains(item.id),
                              onToggleSelection: () =>
                                  _toggleSelection(item.id),
                              onEnterSelection: () => _enterSelection(item.id),
                            );
                          },
                        );
                      },
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (_, _) => Center(child: Text(l.cloudLoadFailed)),
                    ),
                  ),
                ],
              ),
        floatingActionButton: service == null
            ? null
            : FloatingActionButton.extended(
                heroTag: 'xveil-cloud-add',
                onPressed: _busy ? null : _showAddMenu,
                icon: const Icon(Icons.add),
                label: Text(l.cloudAdd),
              ),
      ),
    );
  }
}

/// Owns its text controller so the dialog's exit animation never touches a
/// disposed controller (disposing right after showDialog returns races the
/// route's fade-out).
class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({
    required this.title,
    required this.confirmLabel,
    this.initial,
    this.hint,
  });

  final String title;
  final String confirmLabel;
  final String? initial;
  final String? hint;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('cloud-folder-name'),
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint ?? l.cloudFolderNameHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A one-field prompt that OWNS its controller.
///
/// The three callers of this used to build a `TextEditingController` beside
/// `showDialog` and dispose it on the line after the await. That await returns
/// when `Navigator.pop` runs, and the route keeps its subtree mounted for the
/// exit transition — so the `TextField` went on using a disposed controller.
/// Observed as three errors 0.15 s apart: "A TextEditingController was used
/// after being disposed", then `_dependents.isEmpty` in
/// `InheritedElement.debugDeactivated`, then "Tried to build dirty widget in
/// the wrong build scope" on the dialog's own `_MaterialInterior`. Only the
/// last one reaches the red screen, which is why this read as a framework bug.
///
/// A controller owned by the widget that uses it is disposed when that widget
/// is, which is the only ordering that cannot race the transition.
/// [`_FolderNameDialog`] already did it this way; this is the same shape for
/// the prompts that take a link or a nickname.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.confirmLabel,
    this.hint,
    this.prefixText,
    this.minLines,
    this.maxLines = 1,
  });

  final String title;
  final String confirmLabel;
  final String? hint;
  final String? prefixText;
  final int? minLines;
  final int maxLines;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _text,
        autofocus: true,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixText: widget.prefixText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _text.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _PendingDocumentInvites extends StatefulWidget {
  const _PendingDocumentInvites({required this.service});

  final CloudDocumentReplicationService service;

  @override
  State<_PendingDocumentInvites> createState() =>
      _PendingDocumentInvitesState();
}

class _PendingDocumentInvitesState extends State<_PendingDocumentInvites> {
  StreamSubscription<void>? _subscription;
  List<CloudDocumentPendingInvite> _invites = const [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant _PendingDocumentInvites oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) _listen();
  }

  void _listen() {
    unawaited(_subscription?.cancel());
    _subscription = widget.service.changes.listen((_) => _reload());
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final invites = await widget.service.pendingInvites();
    if (mounted) setState(() => _invites = invites);
  }

  Future<void> _decide(CloudDocumentPendingInvite invite, bool accept) async {
    final id = invite.frame.root.documentId.hex;
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    var ok = true;
    try {
      if (accept) {
        ok = await widget.service.adopt(id);
      } else {
        await widget.service.dismissInvite(id);
      }
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
    if (!mounted) return;
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (accept ? l.cloudDocumentAdopted : l.cloudDocumentRejected)
                : l.cloudDocumentAdoptFailed,
          ),
        ),
      );
    await _reload();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_invites.isEmpty) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ExpansionTile(
        key: const ValueKey('cloud-document-invites'),
        initiallyExpanded: true,
        leading: const Icon(Icons.group_add_outlined),
        title: Text(l.cloudDocumentInvites(_invites.length)),
        children: [
          for (final invite in _invites)
            Padding(
              key: ValueKey(
                'cloud-document-invite-${invite.frame.root.documentId.hex}',
              ),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.cloudDocumentInviteFrom(
                      invite.sender.hex.substring(0, 8),
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l.cloudDocumentInviteKind(
                      _documentKindLabel(l, invite.frame.root.kind),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: _busy.contains(invite.frame.root.documentId.hex)
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: () => _decide(invite, false),
                                child: Text(l.actionReject),
                              ),
                              FilledButton(
                                onPressed: () => _decide(invite, true),
                                child: Text(l.actionAccept),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _documentRoleLabel(AppL10n l, CloudDocumentRole? role) => switch (role) {
  CloudDocumentRole.owner => l.cloudSharedRoleOwner,
  CloudDocumentRole.editor => l.cloudSharedRoleEditor,
  CloudDocumentRole.viewer => l.cloudSharedRoleViewer,
  null => '—',
};

String _documentKindLabel(AppL10n l, CloudDocumentKind kind) => switch (kind) {
  CloudDocumentKind.note => l.cloudKindNote,
  CloudDocumentKind.taskList => l.cloudKindTasks,
  CloudDocumentKind.calendar => l.cloudKindCalendar,
  CloudDocumentKind.fileCollection => l.cloudKindFiles,
};

IconData _documentKindIcon(CloudDocumentKind kind) => switch (kind) {
  CloudDocumentKind.note => Icons.description_outlined,
  CloudDocumentKind.taskList => Icons.task_alt_outlined,
  CloudDocumentKind.calendar => Icons.calendar_month_outlined,
  CloudDocumentKind.fileCollection => Icons.folder_shared_outlined,
};

/// Shared ACL-folder browser: the live file list every member sees, with
/// per-file download over the member content path, and add/remove for
/// owner/editor. Byte pulls are authorized by the document's CURRENT epoch
/// key — a revoked member loses both the address and the subkeys instantly.
class _SharedFolderScreen extends StatefulWidget {
  const _SharedFolderScreen({
    required this.service,
    required this.cloud,
    required this.documentId,
    required this.onClose,
    required this.onManage,
  });

  final CloudDocumentReplicationService service;
  final CloudService cloud;
  final String documentId;
  final VoidCallback onClose;
  final VoidCallback onManage;

  @override
  State<_SharedFolderScreen> createState() => _SharedFolderScreenState();
}

class _SharedFolderScreenState extends State<_SharedFolderScreen> {
  StreamSubscription<void>? _subscription;
  List<CloudFileEntry> _files = const [];
  Map<String, bool> _local = const {};
  bool _canEdit = false;
  bool _loaded = false;
  final Set<String> _busy = {};

  /// Fraction done per entry id while its member pull runs.
  final Map<String, double> _progress = {};

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.changes.listen((_) {
      unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final state = await widget.service.loadCollection(widget.documentId);
    if (state == null || state.kind != CloudDocumentKind.fileCollection) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    final files = state.files;
    final local = <String, bool>{
      for (final entry in files)
        entry.contentId: await widget.service.isSharedFileLocal(
          entry.contentId,
        ),
    };
    if (!mounted) return;
    setState(() {
      _files = files;
      _local = local;
      _canEdit = state.canEdit;
      _loaded = true;
    });
  }

  Future<void> _download(CloudFileEntry entry) async {
    setState(() => _busy.add(entry.id));
    try {
      final fetched = await widget.service.downloadSharedFolderFile(
        widget.documentId,
        entry.id,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress[entry.id] = received / total);
        },
      );
      if (!mounted) return;
      if (fetched == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).cloudSharedFetchFailed)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy.remove(entry.id);
          _progress.remove(entry.id);
        });
      }
      unawaited(_reload());
    }
  }

  Future<void> _remove(CloudFileEntry entry) async {
    await widget.service.removeSharedFolderFile(widget.documentId, entry.id);
    unawaited(_reload());
  }

  Future<void> _addFromCloud() async {
    final l = AppL10n.of(context);
    final items = (await widget.cloud.listItems())
        .where(
          (item) =>
              item.kind == CloudItemKind.file &&
              !item.deleted &&
              item.contentId != null,
        )
        .toList();
    final shared = _files.map((entry) => entry.contentId).toSet();
    final candidates = <CloudItem>[];
    for (final item in items) {
      if (shared.contains(item.contentId)) continue;
      if (await widget.cloud.isLocal(item)) candidates.add(item);
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<CloudItem>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: candidates.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l.cloudSharedAddEmpty, textAlign: TextAlign.center),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final item in candidates)
                    ListTile(
                      key: ValueKey('shared-add-${item.id}'),
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(item.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(formatCloudBytes(item.size)),
                      onTap: () => Navigator.pop(sheetContext, item),
                    ),
                ],
              ),
      ),
    );
    if (picked == null || !mounted) return;
    final cid = picked.contentId!;
    final manifest = await widget.cloud.manifestJsonFor(cid);
    if (manifest == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).cloudSharedFetchFailed)),
        );
      }
      return;
    }
    await widget.service.addSharedFolderFile(
      widget.documentId,
      name: picked.name,
      contentId: cid,
      size: picked.size,
      mime: picked.mime,
      manifest: manifest,
    );
    unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onClose),
        title: Text(l.cloudKindFiles),
        actions: [
          if (_canEdit)
            IconButton(
              key: const ValueKey('shared-folder-add'),
              tooltip: l.cloudSharedAddFile,
              onPressed: _addFromCloud,
              icon: const Icon(Icons.add),
            ),
          IconButton(
            tooltip: l.cloudRichManage,
            onPressed: widget.onManage,
            icon: const Icon(Icons.group_outlined),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l.cloudSharedEmpty, textAlign: TextAlign.center),
              ),
            )
          : ListView(
              children: [
                for (final entry in _files)
                  ListTile(
                    key: ValueKey('shared-file-${entry.id}'),
                    leading: Icon(
                      _local[entry.contentId] == true
                          ? Icons.insert_drive_file
                          : Icons.cloud_outlined,
                    ),
                    title: Text(entry.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(formatCloudBytes(entry.size)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_busy.contains(entry.id))
                          // Determinate once a chunk has landed: a member pull
                          // costs an anonymous round trip per 256 bytes, so a
                          // bare spinner would sit unchanged for minutes and
                          // read as a hang.
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: _progress[entry.id],
                            ),
                          )
                        else if (_local[entry.contentId] != true &&
                            entry.manifest != null)
                          IconButton(
                            key: ValueKey('shared-fetch-${entry.id}'),
                            tooltip: l.cloudSharedFetch,
                            onPressed: () => unawaited(_download(entry)),
                            icon: const Icon(Icons.download_outlined),
                          ),
                        if (_canEdit)
                          IconButton(
                            key: ValueKey('shared-remove-${entry.id}'),
                            tooltip: l.cloudDelete,
                            onPressed: () => unawaited(_remove(entry)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SharedDocumentSection extends StatefulWidget {
  const _SharedDocumentSection({required this.service, required this.cloud});

  final CloudDocumentReplicationService service;
  final CloudService cloud;

  @override
  State<_SharedDocumentSection> createState() => _SharedDocumentSectionState();
}

class _SharedDocumentSectionState extends State<_SharedDocumentSection> {
  StreamSubscription<void>? _subscription;
  List<CloudDocumentView> _documents = const [];

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant _SharedDocumentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) _listen();
  }

  void _listen() {
    unawaited(_subscription?.cancel());
    _subscription = widget.service.changes.listen((_) => _reload());
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final documents = await widget.service.listDocuments();
    if (mounted) setState(() => _documents = documents);
  }

  Future<void> _open(CloudDocumentView document) async {
    var manage = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (pageContext) {
          void close() => Navigator.pop(pageContext);
          void openManage() {
            manage = true;
            Navigator.pop(pageContext);
          }

          final editor = switch (document.root.kind) {
            CloudDocumentKind.note => CloudSharedDocumentEditor(
              service: widget.service,
              documentId: document.root.documentId.hex,
              onClose: close,
              onManage: openManage,
            ),
            CloudDocumentKind.taskList ||
            CloudDocumentKind.calendar => CloudCollectionEditor(
              service: widget.service,
              documentId: document.root.documentId.hex,
              onClose: close,
              onManage: openManage,
            ),
            CloudDocumentKind.fileCollection => _SharedFolderScreen(
              service: widget.service,
              cloud: widget.cloud,
              documentId: document.root.documentId.hex,
              onClose: close,
              onManage: openManage,
            ),
          };
          return Scaffold(body: editor);
        },
      ),
    );
    if (manage && mounted) await _manage(document);
    if (mounted) await _reload();
  }

  Future<void> _manage(CloudDocumentView document) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _DocumentAclSheet(
        service: widget.service,
        cloud: widget.cloud,
        documentId: document.root.documentId.hex,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_documents.isEmpty) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    return ExpansionTile(
      key: const ValueKey('cloud-shared-documents'),
      leading: const Icon(Icons.group_work_outlined),
      title: Text(l.cloudSharedDocuments(_documents.length)),
      children: [
        for (final document in _documents)
          ListTile(
            key: ValueKey(
              'cloud-shared-document-${document.root.documentId.hex}',
            ),
            leading: Icon(_documentKindIcon(document.root.kind)),
            title: Text(
              l.cloudSharedDocument(
                _documentKindLabel(l, document.root.kind),
                document.root.documentId.short,
              ),
            ),
            subtitle: Text(
              l.cloudSharedMembers(
                document.members.length,
                document.currentEpoch,
                _documentRoleLabel(l, document.localRole),
              ),
            ),
            trailing: IconButton(
              key: ValueKey(
                'cloud-shared-manage-${document.root.documentId.hex}',
              ),
              tooltip: l.cloudRichManage,
              onPressed: () => _manage(document),
              icon: const Icon(Icons.group_outlined),
            ),
            onTap: () => _open(document),
          ),
      ],
    );
  }
}

class _DocumentAclSheet extends StatefulWidget {
  const _DocumentAclSheet({
    required this.service,
    required this.cloud,
    required this.documentId,
  });

  final CloudDocumentReplicationService service;
  final CloudService cloud;
  final String documentId;

  @override
  State<_DocumentAclSheet> createState() => _DocumentAclSheetState();
}

class _DocumentAclSheetState extends State<_DocumentAclSheet> {
  StreamSubscription<void>? _subscription;
  CloudDocumentView? _document;
  Map<String, Contact> _contacts = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.changes.listen((_) => _reload());
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final documents = await widget.service.listDocuments();
    final contacts = await widget.cloud.acceptedContacts();
    if (!mounted) return;
    setState(() {
      _document = documents
          .where((entry) => entry.root.documentId.hex == widget.documentId)
          .firstOrNull;
      _contacts = {for (final contact in contacts) contact.nodeId.hex: contact};
    });
  }

  String _memberLabel(String id) =>
      _contacts[id]?.label ?? NodeId.fromHex(id).short;

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runMutation(
    Future<CloudDocumentMutationResult?> Function() mutation,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    CloudDocumentMutationResult? result;
    try {
      result = await mutation();
    } catch (_) {
      result = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final l = AppL10n.of(context);
    _notice(
      result == null
          ? l.cloudSharedFailed
          : result.fullyQueued
          ? l.cloudSharedQueued
          : l.cloudSharedPartial,
    );
    await _reload();
  }

  Future<CloudDocumentRole?> _pickRole() {
    final l = AppL10n.of(context);
    return showDialog<CloudDocumentRole>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.cloudSharedRole),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentRole.editor),
            child: Text(l.cloudSharedRoleEditor),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, CloudDocumentRole.viewer),
            child: Text(l.cloudSharedRoleViewer),
          ),
        ],
      ),
    );
  }

  Future<void> _addMember() async {
    final document = _document;
    if (document == null) return;
    final available = _contacts.values
        .where((contact) => !document.members.containsKey(contact.nodeId.hex))
        .toList();
    if (available.isEmpty) {
      _notice(AppL10n.of(context).cloudNoContacts);
      return;
    }
    final peer = await showDialog<NodeId>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(AppL10n.of(context).cloudSharedPickContact),
        children: [
          for (final contact in available)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, contact.nodeId),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(contact.label),
                subtitle: Text(contact.nodeId.short),
              ),
            ),
        ],
      ),
    );
    if (peer == null || !mounted) return;
    final role = await _pickRole();
    if (role == null || !mounted) return;
    await _runMutation(
      () => widget.service.grant(widget.documentId, peer, role),
    );
  }

  Future<void> _memberAction(String id, String action) async {
    final peer = NodeId.fromHex(id);
    switch (action) {
      case 'editor':
        await _runMutation(
          () => widget.service.setRole(
            widget.documentId,
            peer,
            CloudDocumentRole.editor,
          ),
        );
        return;
      case 'viewer':
        await _runMutation(
          () => widget.service.setRole(
            widget.documentId,
            peer,
            CloudDocumentRole.viewer,
          ),
        );
        return;
      case 'resend':
        setState(() => _busy = true);
        final ok = await widget.service.resendInvite(widget.documentId, peer);
        if (mounted) {
          setState(() => _busy = false);
          _notice(
            ok
                ? AppL10n.of(context).cloudSharedQueued
                : AppL10n.of(context).cloudSharedFailed,
          );
        }
        return;
      case 'revoke':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              AppL10n.of(context).cloudSharedRevokeTitle(_memberLabel(id)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppL10n.of(context).actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppL10n.of(context).cloudSharedRevoke),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted) {
          await _runMutation(
            () => widget.service.revoke(widget.documentId, peer),
          );
        }
    }
  }

  Future<void> _rotate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppL10n.of(context).cloudSharedRotateTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppL10n.of(context).cloudSharedRotate),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runMutation(() => widget.service.rotateEpoch(widget.documentId));
    }
  }

  Future<void> _compact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppL10n.of(context).cloudSharedCompact),
        content: Text(AppL10n.of(context).cloudSharedCompactTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppL10n.of(context).cloudSharedCompact),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      if (_busy) return;
      setState(() => _busy = true);
      var started = false;
      try {
        started = await widget.service.requestQuiescence(
          widget.documentId,
          ignoreThreshold: true,
        );
      } catch (_) {
        started = false;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      _notice(
        started
            ? AppL10n.of(context).cloudSharedQueued
            : AppL10n.of(context).cloudSharedFailed,
      );
      await _reload();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final l = AppL10n.of(context);
    if (document == null) {
      return const SafeArea(child: Center(child: CircularProgressIndicator()));
    }
    final ownerControls = document.localRole == CloudDocumentRole.owner;
    final members = document.members.entries.toList()
      ..sort((left, right) {
        if (left.value == CloudDocumentRole.owner) return -1;
        if (right.value == CloudDocumentRole.owner) return 1;
        return _memberLabel(left.key).compareTo(_memberLabel(right.key));
      });
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(
                l.cloudSharedDocument(
                  document.root.kind.name,
                  document.root.documentId.short,
                ),
              ),
              subtitle: Text(
                l.cloudSharedMembers(
                  document.members.length,
                  document.currentEpoch,
                  _documentRoleLabel(l, document.localRole),
                ),
              ),
              trailing: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            if (ownerControls)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addMember,
                      icon: const Icon(Icons.person_add_outlined),
                      label: Text(l.cloudSharedAddMember),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _rotate,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(l.cloudSharedRotate),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _compact,
                      icon: const Icon(Icons.compress_outlined),
                      label: Text(l.cloudSharedCompact),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final member in members)
                    ListTile(
                      leading: Icon(
                        member.value == CloudDocumentRole.owner
                            ? Icons.verified_user_outlined
                            : Icons.person_outline,
                      ),
                      title: Text(_memberLabel(member.key)),
                      subtitle: Text(_documentRoleLabel(l, member.value)),
                      trailing:
                          ownerControls &&
                              member.value != CloudDocumentRole.owner
                          ? PopupMenuButton<String>(
                              enabled: !_busy,
                              onSelected: (action) =>
                                  _memberAction(member.key, action),
                              itemBuilder: (context) => [
                                if (member.value != CloudDocumentRole.editor)
                                  PopupMenuItem(
                                    value: 'editor',
                                    child: Text(l.cloudSharedRoleEditor),
                                  ),
                                if (member.value != CloudDocumentRole.viewer)
                                  PopupMenuItem(
                                    value: 'viewer',
                                    child: Text(l.cloudSharedRoleViewer),
                                  ),
                                PopupMenuItem(
                                  value: 'resend',
                                  child: Text(l.cloudSharedResend),
                                ),
                                PopupMenuItem(
                                  value: 'revoke',
                                  child: Text(l.cloudSharedRevoke),
                                ),
                              ],
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplicationProfile extends StatefulWidget {
  const _ReplicationProfile({required this.service});

  final CloudService service;

  @override
  State<_ReplicationProfile> createState() => _ReplicationProfileState();
}

class _ReplicationProfileState extends State<_ReplicationProfile> {
  late CloudReplicationMode _mode = widget.service.profile.mode;

  @override
  void didUpdateWidget(covariant _ReplicationProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _mode = widget.service.profile.mode;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListTile(
      leading: const Icon(Icons.sync_outlined),
      title: Text(l.cloudReplication),
      subtitle: Text(switch (_mode) {
        CloudReplicationMode.all => l.cloudModeAllHint,
        CloudReplicationMode.selected => l.cloudModeSelectedHint,
        CloudReplicationMode.indexOnly => l.cloudModeIndexHint,
      }),
      trailing: DropdownButton<CloudReplicationMode>(
        value: _mode,
        onChanged: (mode) async {
          if (mode == null) return;
          final old = widget.service.profile;
          setState(() => _mode = mode);
          await widget.service.setProfile(
            CloudReplicationProfile(
              mode: mode,
              selectedItemIds: old.selectedItemIds,
            ),
          );
        },
        items: [
          DropdownMenuItem(
            value: CloudReplicationMode.all,
            child: Text(l.cloudModeAll),
          ),
          DropdownMenuItem(
            value: CloudReplicationMode.selected,
            child: Text(l.cloudModeSelected),
          ),
          DropdownMenuItem(
            value: CloudReplicationMode.indexOnly,
            child: Text(l.cloudModeIndex),
          ),
        ],
      ),
    );
  }
}

class _EmptyCloud extends StatelessWidget {
  const _EmptyCloud({
    required this.onImport,
    required this.onNote,
    this.title,
    this.hint,
  });

  final VoidCallback? onImport;
  final VoidCallback? onNote;

  /// Overrides for the empty-FOLDER variant; the root defaults stay intact.
  final String? title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              title ?? l.cloudEmpty,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(hint ?? l.cloudEmptyHint, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onNote,
                  icon: const Icon(Icons.note_add_outlined),
                  label: Text(l.cloudAddNote),
                ),
                OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(l.cloudAddFile),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudItemTile extends StatefulWidget {
  const _CloudItemTile({
    super.key,
    required this.item,
    required this.service,
    required this.capabilityService,
    this.pathLabel,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
    this.onEnterSelection,
  });

  final CloudItem item;
  final CloudService service;
  final CloudCapabilityService? capabilityService;

  /// Folder chain shown under search results.
  final String? pathLabel;

  /// Bulk-selection wiring: while [selectionMode] is on, tap toggles the
  /// checkbox instead of opening/fetching; long-press enters the mode.
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onEnterSelection;

  @override
  State<_CloudItemTile> createState() => _CloudItemTileState();
}

class _CloudItemTileState extends State<_CloudItemTile> {
  bool _working = false;
  bool? _local;
  CloudItem? _localNoteHead;
  Uint8List? _preview;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _CloudItemTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Replica claims and integrity results can change without changing the
    // logical item's revision. Re-read local presence on every parent update
    // so the tile never keeps a stale "on this device" badge.
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final localHead = widget.item.kind == CloudItemKind.note
        ? await widget.service.localNoteHead(widget.item)
        : null;
    final local = widget.item.kind == CloudItemKind.note
        ? localHead != null
        : await widget.service.isLocal(widget.item);
    // Null is the ordinary answer — no preview was made, or its bytes have not
    // reached this device — and the icon stands in for it.
    var preview = await widget.service.loadThumbnail(widget.item);
    if (mounted) {
      setState(() {
        _local = local;
        _localNoteHead = localHead;
        _preview = preview;
      });
    }
    // Not here yet: ask for it. Bounded by what is on screen, and cheap enough
    // to be worth doing even on a device that keeps only the index — showing
    // what it is NOT storing is the whole point of a preview.
    if (preview == null && widget.item.thumbContentId != null) {
      if (await widget.service.ensureThumbnail(widget.item)) {
        preview = await widget.service.loadThumbnail(widget.item);
        if (mounted && preview != null) setState(() => _preview = preview);
      }
    }
  }

  Future<void> _fetch() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await widget.service.ensureLocal(widget.item);
      await _refresh();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _export() async {
    if (_working) return;
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _working = true);
    try {
      final result = await exportCloudItem(widget.service, widget.item);
      // Cancelling the save dialog is not a failure and gets no report.
      if (!mounted || result == CloudExportResult.cancelled) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result == CloudExportResult.done
                ? l.cloudExportDone
                : l.cloudExportFailed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openNote() async {
    if (_working || widget.item.kind != CloudItemKind.note) return;
    await Navigator.push<CloudItem>(
      context,
      MaterialPageRoute(
        builder: (context) => CloudNoteEditorScreen(
          service: widget.service,
          item: _localNoteHead ?? widget.item,
        ),
      ),
    );
  }

  Future<void> _toggleSelected() async {
    final profile = widget.service.profile;
    final selected = {...profile.selectedItemIds};
    if (!selected.add(widget.item.id)) selected.remove(widget.item.id);
    await widget.service.setProfile(
      CloudReplicationProfile(mode: profile.mode, selectedItemIds: selected),
    );
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudDeleteTitle),
        content: Text(l.cloudDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudDelete),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.service.deleteItem(widget.item.id);
  }

  Future<void> _share() async {
    final l = AppL10n.of(context);
    final contacts = await widget.service.acceptedContacts();
    if (!mounted) return;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.cloudNoContacts)));
      return;
    }
    final peer = await showModalBottomSheet<NodeId>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: contacts.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return ListTile(title: Text(l.cloudShareTitle));
              final contact = contacts[index - 1];
              final trimmed = contact.label.trim();
              final label = trimmed.isEmpty ? contact.nodeId.short : trimmed;
              return ListTile(
                leading: CircleAvatar(
                  child: Text(label.characters.first.toUpperCase()),
                ),
                title: Text(label),
                subtitle: Text(contact.nodeId.short),
                onTap: () => Navigator.pop(context, contact.nodeId),
              );
            },
          ),
        ),
      ),
    );
    if (peer == null || !mounted) return;
    setState(() => _working = true);
    var ok = false;
    try {
      ok = await widget.service.shareWithContact(widget.item, peer);
    } catch (_) {
      // The durable local row may still be retried, but the UI must always
      // leave its busy state and report that this attempt was not confirmed.
    }
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l.cloudShared : l.cloudShareFailed)),
    );
  }

  Future<void> _sharePublic() async {
    final service = widget.capabilityService;
    if (service == null || _working) return;
    final l = AppL10n.of(context);
    setState(() => _working = true);
    try {
      final existing = (await service.listShares())
          .where((share) => share.itemId == widget.item.id)
          .firstOrNull;
      if (!mounted) return;
      if (existing != null) {
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.cloudPublicLink),
            content: SelectableText(existing.link, maxLines: 5),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'revoke'),
                child: Text(l.cloudPublicRevoke),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'copy'),
                child: Text(l.cloudPublicCopy),
              ),
            ],
          ),
        );
        if (action == 'revoke') {
          await service.revoke(existing.shareId);
          if (mounted) _notice(l.cloudPublicRevoked);
          return;
        }
        if (action == 'copy') {
          await Clipboard.setData(ClipboardData(text: existing.link));
          if (mounted) _notice(l.cloudPublicCopied);
        }
        return;
      }
      final share = await service.createShare(widget.item);
      await Clipboard.setData(ClipboardData(text: share.link));
      if (mounted) _notice(l.cloudPublicCopied);
    } catch (_) {
      if (mounted) _notice(l.cloudPublicFailed);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _rename() async {
    if (_working || widget.item.kind != CloudItemKind.file) return;
    final l = AppL10n.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _FolderNameDialog(
        title: l.cloudRename,
        confirmLabel: l.cloudRename,
        initial: widget.item.name,
        hint: l.cloudRenameHint,
      ),
    );
    if (name == null || name.isEmpty || name == widget.item.name || !mounted) {
      return;
    }
    try {
      await widget.service.renameItem(widget.item.id, name);
    } catch (_) {
      if (mounted) _notice(l.cloudRenameFailed);
    }
  }

  Future<void> _move() async {
    if (_working) return;
    final l = AppL10n.of(context);
    final tree = widget.service.folderChildrenIndex();
    final rows = <({CloudFolder folder, int depth})>[];
    void walk(String? parentId, int depth) {
      if (depth > 32) return;
      for (final folder in tree[parentId] ?? const <CloudFolder>[]) {
        rows.add((folder: folder, depth: depth));
        walk(folder.id, depth + 1);
      }
    }

    walk(null, 0);
    final current = widget.service.effectiveFolderId(widget.item);
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(l.cloudMoveToFolder)),
              ListTile(
                key: const ValueKey('cloud-move-root'),
                leading: const Icon(Icons.home_outlined),
                title: Text(l.cloudMoveToRoot),
                trailing: current == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final row in rows)
                ListTile(
                  key: ValueKey('cloud-move-${row.folder.id}'),
                  leading: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 16.0 * row.depth,
                    ),
                    child: const Icon(Icons.folder_outlined),
                  ),
                  title: Text(
                    row.folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: current == row.folder.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, row.folder.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    try {
      await widget.service.moveItemToFolder(
        widget.item.id,
        target.isEmpty ? null : target,
      );
      if (mounted) _notice(l.cloudFolderMoved);
    } catch (_) {
      if (mounted) _notice(l.cloudFolderFailed);
    }
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final replicas = widget.service.replicaCount(widget.item);
    final selected = widget.service.profile.selectedItemIds.contains(
      widget.item.id,
    );
    final noteHeads = widget.item.kind == CloudItemKind.note
        ? widget.service.noteHeads(widget.item).length
        : 1;
    // A locally-present file with fewer than two verified replicas would be
    // lost with this device — surface that as an inline warning.
    final singleCopy =
        widget.item.kind == CloudItemKind.file &&
        _local == true &&
        replicas < 2;
    final subtitle =
        '${formatCloudBytes(widget.item.size)} · '
        '${_local == true ? l.cloudLocal : l.cloudRemote} · '
        '${l.cloudReplicas(replicas)}'
        '${singleCopy ? ' · ${l.cloudSingleCopy}' : ''}'
        '${noteHeads > 1 ? ' · ${l.cloudNoteBranches(noteHeads)}' : ''}'
        // Only ever says this about a change that arrived from elsewhere after
        // this device had acknowledged the row — our own edits and rows never
        // seen before are not news.
        '${widget.service.changedElsewhere(widget.item) ? ' · ${l.cloudChangedElsewhere}' : ''}';
    return ListTile(
      leading: widget.selectionMode
          ? Checkbox(
              value: widget.selected,
              onChanged: (_) => widget.onToggleSelection?.call(),
            )
          : _working
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _preview != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                _preview!,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                // A preview is decoration; if its bytes turn out to be junk the
                // row still has to render.
                errorBuilder: (_, _, _) => const Icon(Icons.cloud_done),
              ),
            )
          : Icon(
              widget.item.kind == CloudItemKind.note
                  ? Icons.note_outlined
                  : _local == true
                  ? Icons.cloud_done
                  : Icons.cloud_download,
            ),
      title: Text(
        widget.item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        widget.pathLabel == null ? subtitle : '$subtitle\n${widget.pathLabel}',
      ),
      selected: widget.selectionMode && widget.selected,
      onTap: widget.selectionMode
          ? widget.onToggleSelection
          : widget.item.kind == CloudItemKind.note && _local == true
          ? () {
              unawaited(widget.service.markSeen(widget.item));
              unawaited(_openNote());
            }
          : _local == true
          ? null
          : _fetch,
      onLongPress: widget.selectionMode
          ? widget.onToggleSelection
          : widget.onEnterSelection,
      trailing: widget.selectionMode
          ? null
          // Keyed because the app bar now carries a menu of its own: two
          // identical more_vert glyphs on one screen are ambiguous to a finder
          // and, more to the point, to a person.
          : PopupMenuButton<String>(
              key: ValueKey('cloud-item-menu-${widget.item.id}'),
              onSelected: (action) {
                switch (action) {
                  case 'fetch':
                    unawaited(_fetch());
                  case 'selected':
                    unawaited(_toggleSelected());
                  case 'rename':
                    unawaited(_rename());
                  case 'move':
                    unawaited(_move());
                  case 'verify':
                    unawaited(
                      widget.service.verifyItem(widget.item, repair: true),
                    );
                  case 'export':
                    unawaited(_export());
                  case 'share':
                    unawaited(_share());
                  case 'public':
                    unawaited(_sharePublic());
                  case 'delete':
                    unawaited(_delete());
                }
              },
              itemBuilder: (context) => [
                if (_local != true)
                  PopupMenuItem(value: 'fetch', child: Text(l.cloudDownload)),
                PopupMenuItem(
                  value: 'selected',
                  child: Text(selected ? l.cloudUnselect : l.cloudSelect),
                ),
                if (widget.item.kind == CloudItemKind.file)
                  PopupMenuItem(value: 'rename', child: Text(l.cloudRename)),
                if (widget.item.kind == CloudItemKind.file &&
                    widget.item.contentId != null)
                  PopupMenuItem(value: 'export', child: Text(l.cloudExport)),
                PopupMenuItem(value: 'move', child: Text(l.cloudMoveToFolder)),
                if (_local == true)
                  PopupMenuItem(value: 'verify', child: Text(l.cloudVerify)),
                if (_local == true)
                  PopupMenuItem(value: 'share', child: Text(l.cloudShare)),
                if (_local == true && widget.capabilityService != null)
                  PopupMenuItem(
                    value: 'public',
                    child: Text(l.cloudPublicLink),
                  ),
                PopupMenuItem(value: 'delete', child: Text(l.cloudDelete)),
              ],
            ),
    );
  }
}

/// Browses one received folder bearer link: fetches the listing anonymously,
/// renders the (read-only) tree, and downloads+adopts individual files on
/// demand. No content bytes are held until the user taps download.
class CloudReceivedFolderScreen extends StatefulWidget {
  const CloudReceivedFolderScreen({
    super.key,
    required this.capabilities,
    required this.cloud,
    required this.link,
  });

  final CloudCapabilityService capabilities;
  final CloudService cloud;
  final String link;

  @override
  State<CloudReceivedFolderScreen> createState() =>
      _CloudReceivedFolderScreenState();
}

class _CloudReceivedFolderScreenState extends State<CloudReceivedFolderScreen> {
  CloudFolderListing? _listing;
  String? _error;
  bool _loading = true;
  final Set<String> _downloading = {};
  final Set<String> _done = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final listing = await widget.capabilities.fetchFolderListing(widget.link);
      if (mounted) setState(() => _listing = listing);
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppL10n.of(context).cloudFolderOpenFailed);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(CloudFolderListingEntry entry) async {
    final cid = entry.manifest!.contentId;
    if (_downloading.contains(cid)) return;
    setState(() => _downloading.add(cid));
    final l = AppL10n.of(context);
    try {
      final capability = await widget.capabilities.downloadFolderFile(
        widget.link,
        entry,
      );
      await widget.cloud.adoptCapability(capability);
      if (mounted) {
        setState(() => _done.add(cid));
        _notice(l.cloudFolderFileDownloaded);
      }
    } catch (_) {
      if (mounted) _notice(l.cloudFolderFileFailed);
    } finally {
      if (mounted) setState(() => _downloading.remove(cid));
    }
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  List<Widget> _rows(List<CloudFolderListingEntry> entries, int depth) {
    final widgets = <Widget>[];
    for (final entry in entries) {
      final pad = EdgeInsetsDirectional.only(start: 16.0 + 16.0 * depth);
      if (entry.isFolder) {
        widgets.add(
          ListTile(
            contentPadding: pad,
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              entry.name!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        widgets.addAll(_rows(entry.entries!, depth + 1));
      } else {
        final cid = entry.manifest!.contentId;
        final l = AppL10n.of(context);
        widgets.add(
          ListTile(
            contentPadding: pad,
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(
              entry.name!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(formatCloudBytes(entry.size ?? 0)),
            trailing: _done.contains(cid)
                ? const Icon(Icons.cloud_done)
                : _downloading.contains(cid)
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    key: ValueKey('cloud-folder-file-$cid'),
                    onPressed: () => unawaited(_download(entry)),
                    child: Text(l.cloudFolderFileDownload),
                  ),
          ),
        );
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final listing = _listing;
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(listing?.name ?? l.cloudFolderOpenTitle),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : listing == null
          ? Center(child: Text(l.cloudFolderOpenFailed))
          : ListView(children: _rows(listing.entries, 0)),
    );
  }
}
