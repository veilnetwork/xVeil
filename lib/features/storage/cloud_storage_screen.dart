import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/cloud.dart';
import '../../domain/cloud_capability.dart';
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

class _CloudStorageScreenState extends ConsumerState<CloudStorageScreen> {
  bool _busy = false;

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

  Future<void> _importFile() async {
    final service = _service;
    if (service == null || _busy) return;
    final picked = await FilePicker.pickFiles(
      allowMultiple: false,
      withData: false,
      withReadStream: false,
    );
    if (!mounted || picked == null || picked.files.single.path == null) return;
    final path = picked.files.single.path!;
    final name = picked.files.single.name;
    setState(() => _busy = true);
    _RangeFileReader? reader;
    try {
      final file = File(path);
      final size = await file.length();
      reader = _RangeFileReader(await file.open(mode: FileMode.read));
      await service.importContent(
        name: name,
        size: size,
        readRange: reader.read,
        folderId: _openFolderId,
      );
      if (mounted) _notice(AppL10n.of(context).cloudImported);
    } catch (_) {
      if (mounted) _notice(AppL10n.of(context).cloudImportFailed);
    } finally {
      await reader?.close();
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

  Future<void> _openFolderLink() async {
    final capabilities = _capabilityService;
    final cloud = _service;
    if (capabilities == null || cloud == null) return;
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudFolderOpen),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: l.cloudFolderOpenHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l.cloudDownload),
          ),
        ],
      ),
    );
    controller.dispose();
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
    final controller = TextEditingController();
    final l = AppL10n.of(context);
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudPublicImport),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: l.cloudPublicPasteHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l.cloudDownload),
          ),
        ],
      ),
    );
    controller.dispose();
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
              ? null
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
              PopupMenuButton<_CloudSortMode>(
                key: const ValueKey('cloud-sort'),
                tooltip: l.cloudSort,
                icon: const Icon(Icons.sort),
                initialValue: _sort,
                onSelected: (mode) => setState(() => _sort = mode),
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(
                    value: _CloudSortMode.name,
                    checked: _sort == _CloudSortMode.name,
                    child: Text(l.cloudSortByName),
                  ),
                  CheckedPopupMenuItem(
                    value: _CloudSortMode.date,
                    checked: _sort == _CloudSortMode.date,
                    child: Text(l.cloudSortByDate),
                  ),
                  CheckedPopupMenuItem(
                    value: _CloudSortMode.size,
                    checked: _sort == _CloudSortMode.size,
                    child: Text(l.cloudSortBySize),
                  ),
                ],
              ),
              if (ref.watch(cloudCapabilityServiceProvider) != null)
                IconButton(
                  tooltip: l.cloudPublicImport,
                  onPressed: _busy ? null : _importPublicLink,
                  icon: const Icon(Icons.link),
                ),
              IconButton(
                tooltip: l.cloudVerify,
                onPressed: service == null || _busy ? null : _verifyAll,
                icon: const Icon(Icons.health_and_safety_outlined),
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
                  if (openFolder == null) _ReplicationProfile(service: service),
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

/// Interim shared-folder screen: the file browser is a later brick, but the
/// ACL sheet is reachable so an adopted folder stays manageable.
class _SharedFolderPlaceholder extends StatelessWidget {
  const _SharedFolderPlaceholder({
    required this.onClose,
    required this.onManage,
  });

  final VoidCallback onClose;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onClose),
        title: Text(l.cloudKindFiles),
        actions: [
          IconButton(
            tooltip: l.cloudRichManage,
            onPressed: onManage,
            icon: const Icon(Icons.group_outlined),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(l.cloudKindFiles, textAlign: TextAlign.center),
        ),
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
            // The shared-folder browser is a later brick; the ACL sheet is
            // reachable here so an adopted folder is still manageable.
            CloudDocumentKind.fileCollection => _SharedFolderPlaceholder(
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
    if (mounted) {
      setState(() {
        _local = local;
        _localNoteHead = localHead;
      });
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
        '${_formatBytes(widget.item.size)} · '
        '${_local == true ? l.cloudLocal : l.cloudRemote} · '
        '${l.cloudReplicas(replicas)}'
        '${singleCopy ? ' · ${l.cloudSingleCopy}' : ''}'
        '${noteHeads > 1 ? ' · ${l.cloudNoteBranches(noteHeads)}' : ''}';
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
          ? _openNote
          : _local == true
          ? null
          : _fetch,
      onLongPress: widget.selectionMode
          ? widget.onToggleSelection
          : widget.onEnterSelection,
      trailing: widget.selectionMode
          ? null
          : PopupMenuButton<String>(
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

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
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
            subtitle: Text(_formatBytes(entry.size ?? 0)),
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
      appBar: AppBar(title: Text(listing?.name ?? l.cloudFolderOpenTitle)),
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

/// A RandomAccessFile has one mutable cursor. [ContentManifest.fromReader]
/// prefetches the next range, so serialize cursor moves without buffering the
/// whole source in memory.
class _RangeFileReader {
  _RangeFileReader(this._file);

  final RandomAccessFile _file;
  Future<void> _gate = Future.value();

  Future<Uint8List> read(int offset, int length) {
    final result = _gate.then((_) async {
      await _file.setPosition(offset);
      return Uint8List.fromList(await _file.read(length));
    });
    _gate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() => _gate.then((_) => _file.close());
}
