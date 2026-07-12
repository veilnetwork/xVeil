import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/cloud.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_service.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text(l.cloudTitle),
        actions: [
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
                _ReplicationProfile(service: service),
                const Divider(height: 1),
                Expanded(
                  child: items.when(
                    data: (rows) => rows.isEmpty
                        ? _EmptyCloud(onImport: _busy ? null : _importFile)
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: rows.length,
                            itemBuilder: (context, index) => _CloudItemTile(
                              key: ValueKey(
                                '${rows[index].id}:${rows[index].revision}',
                              ),
                              item: rows[index],
                              service: service,
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
              onPressed: _busy ? null : _importFile,
              icon: const Icon(Icons.add),
              label: Text(l.cloudAddFile),
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
  const _EmptyCloud({required this.onImport});

  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_outlined, size: 56),
            const SizedBox(height: 16),
            Text(l.cloudEmpty, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l.cloudEmptyHint, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: Text(l.cloudAddFile),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudItemTile extends StatefulWidget {
  const _CloudItemTile({super.key, required this.item, required this.service});

  final CloudItem item;
  final CloudService service;

  @override
  State<_CloudItemTile> createState() => _CloudItemTileState();
}

class _CloudItemTileState extends State<_CloudItemTile> {
  bool _working = false;
  bool? _local;

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
    final local = await widget.service.isLocal(widget.item);
    if (mounted) setState(() => _local = local);
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

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final replicas = widget.service.replicaCount(widget.item);
    final selected = widget.service.profile.selectedItemIds.contains(
      widget.item.id,
    );
    return ListTile(
      leading: _working
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_local == true ? Icons.cloud_done : Icons.cloud_download),
      title: Text(
        widget.item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatBytes(widget.item.size)} · '
        '${_local == true ? l.cloudLocal : l.cloudRemote} · '
        '${l.cloudReplicas(replicas)}',
      ),
      onTap: _local == true ? null : _fetch,
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
