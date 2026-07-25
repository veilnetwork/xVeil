import 'dart:convert';

import 'package:flutter/material.dart';

import '../../domain/cloud.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_service.dart';

class CloudNoteEditorScreen extends StatefulWidget {
  const CloudNoteEditorScreen({
    super.key,
    required this.service,
    this.item,
    this.folderId,
  });

  final CloudService service;
  final CloudItem? item;

  /// Target folder for a brand-new note; ignored when editing (the service
  /// keeps an edited note where it lives).
  final String? folderId;

  @override
  State<CloudNoteEditorScreen> createState() => _CloudNoteEditorScreenState();
}

class _CloudNoteEditorScreenState extends State<CloudNoteEditorScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  CloudItem? _item;
  bool _loading = false;
  bool _saving = false;
  String? _loadError;
  List<CloudItem> _heads = const [];
  Set<String>? _mergeParents;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    if (_item != null) {
      _title.text = _item!.name;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final body = await widget.service.loadTextNote(_item!);
      if (!mounted) return;
      _body.text = body;
      _heads = widget.service.noteHeads(_item!);
    } catch (_) {
      if (!mounted) return;
      _loadError = AppL10n.of(context).cloudNoteLoadFailed;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reviewBranches() async {
    if (_item == null || _heads.length < 2 || _saving) return;
    final l = AppL10n.of(context);
    final currentRows = (await widget.service.listItems())
        .where((item) => item.id == _item!.id)
        .toList();
    if (!mounted || currentRows.isEmpty) return;
    final current = currentRows.first;
    final selectedHeads = [
      for (final head in _heads)
        if (head.contentId == current.contentId) head,
      for (final head in _heads)
        if (head.contentId != current.contentId) head,
    ].take(CloudItem.maxNoteParents).toList();
    final versions = <_LoadedBranch>[];
    for (final head in selectedHeads) {
      try {
        final body = head.contentId == _item!.contentId
            ? _body.text
            : await widget.service.loadTextNote(head);
        versions.add(_LoadedBranch(head, body));
      } catch (_) {
        if (mounted) _notice(l.cloudNoteBranchesUnavailable);
        return;
      }
    }
    if (!mounted) return;
    final resolution = await showDialog<_ConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ConflictDialog(
        versions: versions,
        draftTitle: _title.text,
        draftBody: _body.text,
      ),
    );
    if (!mounted || resolution == null) return;
    _item = current;
    if (resolution.useRemote) {
      final currentVersion = versions
          .where((version) => version.item.contentId == _item!.contentId)
          .first;
      _title.text = currentVersion.item.name;
      _body.text = currentVersion.body;
    } else {
      _title.text = resolution.title;
      _body.text = resolution.body;
    }
    setState(() {
      _mergeParents = {for (final head in selectedHeads) head.contentId!};
    });
    _notice(l.cloudNoteMergeReady);
  }

  Future<void> _save() async {
    if (_loading || _saving) return;
    final l = AppL10n.of(context);
    if (_title.text.trim().isEmpty) {
      _notice(l.cloudNoteTitleRequired);
      return;
    }
    if (utf8.encode(_body.text).length > CloudService.maxTextNoteBytes) {
      _notice(l.cloudNoteTooLarge);
      return;
    }
    setState(() => _saving = true);
    try {
      while (mounted) {
        try {
          final saved = await widget.service.saveTextNote(
            itemId: _item?.id,
            expectedRevision: _item?.revision,
            expectedContentId: _item?.contentId,
            title: _title.text,
            body: _body.text,
            mergeParentContentIds: _mergeParents,
            folderId: widget.folderId,
          );
          if (!mounted) return;
          Navigator.pop(context, saved);
          return;
        } on CloudEditConflict catch (conflict) {
          final remoteBody = await widget.service.loadTextNote(
            conflict.current,
          );
          if (!mounted) return;
          _item = conflict.current;
          _heads = widget.service.noteHeads(conflict.current);
          final selectedHeads = [
            for (final head in _heads)
              if (head.contentId == conflict.current.contentId) head,
            for (final head in _heads)
              if (head.contentId != conflict.current.contentId) head,
          ].take(CloudItem.maxNoteParents).toList();
          final versions = <_LoadedBranch>[];
          var allLoaded = true;
          for (final head in selectedHeads) {
            try {
              versions.add(
                _LoadedBranch(
                  head,
                  head.contentId == conflict.current.contentId
                      ? remoteBody
                      : await widget.service.loadTextNote(head),
                ),
              );
            } catch (_) {
              allLoaded = false;
              break;
            }
          }
          if (!mounted) return;
          if (!allLoaded) {
            _notice(l.cloudNoteBranchesUnavailable);
            return;
          }
          final resolution = await showDialog<_ConflictResolution>(
            context: context,
            barrierDismissible: false,
            builder: (context) => _ConflictDialog(
              versions: versions,
              draftTitle: _title.text,
              draftBody: _body.text,
            ),
          );
          if (!mounted || resolution == null) return;
          if (resolution.useRemote) {
            _title.text = conflict.current.name;
            _body.text = remoteBody;
            _mergeParents = null;
            return;
          }
          _title.text = resolution.title;
          _body.text = resolution.body;
          _mergeParents = {for (final head in selectedHeads) head.contentId!};
          if (_title.text.trim().isEmpty) {
            _notice(l.cloudNoteTitleRequired);
            return;
          }
          if (utf8.encode(_body.text).length > CloudService.maxTextNoteBytes) {
            _notice(l.cloudNoteTooLarge);
            return;
          }
        }
      }
    } catch (_) {
      if (mounted) _notice(l.cloudNoteSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_item == null ? l.cloudNoteNew : l.cloudNoteEdit),
          actions: [
            TextButton.icon(
              onPressed: _loading || _saving || _loadError != null
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(l.cloudNoteSave),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(child: Text(_loadError!))
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (_heads.length > 1) ...[
                        Card(
                          color: Theme.of(
                            context,
                          ).colorScheme.tertiaryContainer,
                          child: ListTile(
                            leading: const Icon(Icons.call_split_outlined),
                            title: Text(l.cloudNoteBranches(_heads.length)),
                            subtitle: _mergeParents == null
                                ? null
                                : Text(l.cloudNoteMergeReady),
                            trailing: TextButton(
                              onPressed: _reviewBranches,
                              child: Text(l.cloudNoteReviewBranches),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TextField(
                        controller: _title,
                        autofocus: _item == null,
                        maxLength: 512,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l.cloudNoteTitleHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: TextField(
                          controller: _body,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: InputDecoration(
                            hintText: l.cloudNoteBodyHint,
                            alignLabelWithHint: true,
                            border: const OutlineInputBorder(),
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

class _ConflictResolution {
  const _ConflictResolution.remote() : useRemote = true, title = '', body = '';

  const _ConflictResolution.merged(this.title, this.body) : useRemote = false;

  final bool useRemote;
  final String title;
  final String body;
}

class _LoadedBranch {
  const _LoadedBranch(this.item, this.body);

  final CloudItem item;
  final String body;
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({
    required this.versions,
    required this.draftTitle,
    required this.draftBody,
  });

  final List<_LoadedBranch> versions;
  final String draftTitle;
  final String draftBody;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.draftTitle,
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.draftBody,
  );

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.cloudNoteConflictTitle),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.cloudNoteConflictBody),
              const SizedBox(height: 16),
              for (var index = 0; index < widget.versions.length; index++) ...[
                Text(
                  widget.versions.length == 1
                      ? l.cloudNoteRemoteVersion
                      : l.cloudNoteVersion(index + 1),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      '${widget.versions[index].item.name}\n\n'
                      '${widget.versions[index].body}',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                l.cloudNoteYourDraft,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _title,
                maxLength: 512,
                decoration: InputDecoration(
                  labelText: l.cloudNoteTitleHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _body,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(
                  hintText: l.cloudNoteBodyHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const _ConflictResolution.remote()),
          child: Text(l.cloudNoteUseRemote),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ConflictResolution.merged(_title.text, _body.text),
          ),
          child: Text(l.cloudNoteSaveMerged),
        ),
      ],
    );
  }
}
