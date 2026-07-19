import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/cloud.dart';
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

class _CloudStorageScreenState extends ConsumerState<CloudStorageScreen> {
  bool _busy = false;

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
        builder: (context) => CloudNoteEditorScreen(service: service),
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
    if (action == 'shared') await _createSharedDocument();
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
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(cloudServiceProvider);
    final items = ref.watch(cloudItemsProvider);
    final documentService = ref.watch(cloudDocumentReplicationServiceProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.cloudTitle),
        actions: [
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
                if (documentService != null)
                  _PendingDocumentInvites(service: documentService),
                if (documentService != null)
                  _SharedDocumentSection(
                    service: documentService,
                    cloud: service,
                  ),
                _ReplicationProfile(service: service),
                const Divider(height: 1),
                Expanded(
                  child: items.when(
                    data: (rows) => rows.isEmpty
                        ? _EmptyCloud(
                            onImport: _busy ? null : _importFile,
                            onNote: _busy ? null : _createNote,
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: rows.length,
                            itemBuilder: (context, index) => _CloudItemTile(
                              key: ValueKey(
                                '${rows[index].id}:${rows[index].revision}',
                              ),
                              item: rows[index],
                              service: service,
                              capabilityService: ref.watch(
                                cloudCapabilityServiceProvider,
                              ),
                            ),
                          ),
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
};

IconData _documentKindIcon(CloudDocumentKind kind) => switch (kind) {
  CloudDocumentKind.note => Icons.description_outlined,
  CloudDocumentKind.taskList => Icons.task_alt_outlined,
  CloudDocumentKind.calendar => Icons.calendar_month_outlined,
};

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
  const _EmptyCloud({required this.onImport, required this.onNote});

  final VoidCallback? onImport;
  final VoidCallback? onNote;

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
            Text(l.cloudEmpty, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l.cloudEmptyHint, textAlign: TextAlign.center),
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
  });

  final CloudItem item;
  final CloudService service;
  final CloudCapabilityService? capabilityService;

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
    return ListTile(
      leading: _working
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
        '${_formatBytes(widget.item.size)} · '
        '${_local == true ? l.cloudLocal : l.cloudRemote} · '
        '${l.cloudReplicas(replicas)}'
        '${noteHeads > 1 ? ' · ${l.cloudNoteBranches(noteHeads)}' : ''}',
      ),
      onTap: widget.item.kind == CloudItemKind.note && _local == true
          ? _openNote
          : _local == true
          ? null
          : _fetch,
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'fetch':
              unawaited(_fetch());
            case 'selected':
              unawaited(_toggleSelected());
            case 'verify':
              unawaited(widget.service.verifyItem(widget.item, repair: true));
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
          if (_local == true)
            PopupMenuItem(value: 'verify', child: Text(l.cloudVerify)),
          if (_local == true)
            PopupMenuItem(value: 'share', child: Text(l.cloudShare)),
          if (_local == true && widget.capabilityService != null)
            PopupMenuItem(value: 'public', child: Text(l.cloudPublicLink)),
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
