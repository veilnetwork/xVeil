import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/cloud_collection_crdt.dart';
import '../../domain/cloud_document.dart';
import '../../l10n/app_localizations.dart';
import '../../state/cloud_document_replication_service.dart';

class CloudCollectionEditor extends StatefulWidget {
  const CloudCollectionEditor({
    super.key,
    required this.service,
    required this.documentId,
    this.onManage,
    this.onClose,
  });

  final CloudDocumentReplicationService service;
  final String documentId;
  final VoidCallback? onManage;
  final VoidCallback? onClose;

  @override
  State<CloudCollectionEditor> createState() => _CloudCollectionEditorState();
}

class _CloudCollectionEditorState extends State<CloudCollectionEditor> {
  StreamSubscription<void>? _subscription;
  CloudCollectionDocumentState? _state;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CloudCollectionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) _listen();
    if (!identical(oldWidget.service, widget.service) ||
        oldWidget.documentId != widget.documentId) {
      _loading = true;
      _state = null;
      unawaited(_load());
    }
  }

  void _listen() {
    unawaited(_subscription?.cancel());
    _subscription = widget.service.changes.listen((_) => _load());
  }

  Future<void> _load() async {
    final state = await widget.service.loadCollection(widget.documentId);
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _mutate(
    Future<CloudDocumentMutationResult?> Function() mutation,
  ) async {
    if (_busy) return false;
    setState(() => _busy = true);
    CloudDocumentMutationResult? result;
    try {
      result = await mutation();
    } catch (_) {
      result = null;
    }
    if (!mounted) return false;
    final l = AppL10n.of(context);
    _notice(
      result == null
          ? l.cloudCollectionFailed
          : result.fullyQueued
          ? l.cloudCollectionSaved
          : l.cloudSharedPartial,
    );
    setState(() => _busy = false);
    if (result != null) await _load();
    return result != null;
  }

  Future<void> _toggleTask(CloudTask task, bool completed) async {
    final state = _state;
    if (state == null || !state.canEdit) return;
    await _mutate(
      () => widget.service.appendCollectionEdits(widget.documentId, [
        CloudCollectionEdit.patch(task.id, {'completed': completed}),
      ], parentOperationIds: state.snapshot.headOperationIds),
    );
  }

  Future<void> _editTask([CloudTask? task]) async {
    final state = _state;
    if (state == null || !state.canEdit || _busy) return;
    final title = TextEditingController(text: task?.title);
    final notes = TextEditingController(text: task?.notes);
    var due = task?.dueAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(task!.dueAtMs!);
    final l = AppL10n.of(context);
    final submitted =
        await showDialog<({String title, String notes, int? due})>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(task == null ? l.cloudTaskAdd : l.cloudTaskEdit),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey('cloud-task-title'),
                      controller: title,
                      autofocus: true,
                      maxLength: 256,
                      decoration: InputDecoration(labelText: l.cloudTaskTitle),
                    ),
                    TextField(
                      key: const ValueKey('cloud-task-notes'),
                      controller: notes,
                      maxLines: 4,
                      decoration: InputDecoration(labelText: l.cloudTaskNotes),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_outlined),
                      title: Text(l.cloudTaskDue),
                      subtitle: Text(
                        due == null
                            ? l.cloudTaskNoDue
                            : _formatDate(context, due!),
                      ),
                      trailing: due == null
                          ? null
                          : IconButton(
                              onPressed: () => setDialogState(() => due = null),
                              icon: const Icon(Icons.clear),
                            ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: due ?? DateTime.now(),
                          firstDate: DateTime(1970),
                          lastDate: DateTime(2200),
                        );
                        if (picked != null) setDialogState(() => due = picked);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.actionCancel),
                ),
                FilledButton(
                  onPressed: () {
                    final value = title.text.trim();
                    if (value.isEmpty) return;
                    Navigator.pop(context, (
                      title: value,
                      notes: notes.text,
                      due: due?.millisecondsSinceEpoch,
                    ));
                  },
                  child: Text(l.actionSave),
                ),
              ],
            ),
          ),
        );
    // The dialog future resolves on pop while the reverse route animation can
    // still build EditableText for one frame. Dispose after that transition.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    title.dispose();
    notes.dispose();
    if (submitted == null || !mounted) return;
    final CloudCollectionEdit edit;
    if (task == null) {
      final id = widget.service.newCollectionEntityId();
      edit = CloudCollectionEdit.create(
        id,
        CloudTask(
          id: id,
          title: submitted.title,
          notes: submitted.notes,
          completed: false,
          dueAtMs: submitted.due,
          position: state.tasks.length,
        ).toFields(),
      );
    } else {
      edit = CloudCollectionEdit.patch(task.id, {
        if (submitted.title != task.title) 'title': submitted.title,
        if (submitted.notes != task.notes) 'notes': submitted.notes,
        if (submitted.due != task.dueAtMs) 'due': submitted.due,
      });
    }
    if (edit.kind == CloudCollectionEditKind.patch && edit.fields.isEmpty) {
      return;
    }
    await _mutate(
      () => widget.service.appendCollectionEdits(widget.documentId, [
        edit,
      ], parentOperationIds: state.snapshot.headOperationIds),
    );
  }

  Future<void> _editEvent([CloudCalendarEvent? event]) async {
    final state = _state;
    if (state == null || !state.canEdit || _busy) return;
    final title = TextEditingController(text: event?.title);
    final notes = TextEditingController(text: event?.notes);
    final location = TextEditingController(text: event?.location);
    final now = DateTime.now();
    var start = event == null
        ? DateTime(now.year, now.month, now.day, now.hour + 1)
        : DateTime.fromMillisecondsSinceEpoch(event.startAtMs);
    var end = event == null
        ? start.add(const Duration(hours: 1))
        : DateTime.fromMillisecondsSinceEpoch(event.endAtMs);
    var allDay = event?.allDay ?? false;
    final l = AppL10n.of(context);
    final submitted =
        await showDialog<
          ({
            String title,
            String notes,
            String location,
            int start,
            int end,
            bool allDay,
          })
        >(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(event == null ? l.cloudEventAdd : l.cloudEventEdit),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey('cloud-event-title'),
                      controller: title,
                      autofocus: true,
                      maxLength: 256,
                      decoration: InputDecoration(labelText: l.cloudEventTitle),
                    ),
                    TextField(
                      controller: notes,
                      maxLines: 3,
                      decoration: InputDecoration(labelText: l.cloudTaskNotes),
                    ),
                    TextField(
                      controller: location,
                      decoration: InputDecoration(
                        labelText: l.cloudEventLocation,
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.cloudEventAllDay),
                      value: allDay,
                      onChanged: (value) =>
                          setDialogState(() => allDay = value),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.cloudEventStart),
                      subtitle: Text(_formatDateTime(context, start, allDay)),
                      onTap: () async {
                        final picked = await _pickDateTime(
                          context,
                          start,
                          allDay: allDay,
                        );
                        if (picked != null) {
                          setDialogState(() => start = picked);
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.cloudEventEnd),
                      subtitle: Text(_formatDateTime(context, end, allDay)),
                      onTap: () async {
                        final picked = await _pickDateTime(
                          context,
                          end,
                          allDay: allDay,
                        );
                        if (picked != null) setDialogState(() => end = picked);
                      },
                    ),
                    if (end.isBefore(start))
                      Text(
                        l.cloudCollectionInvalidRange,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.actionCancel),
                ),
                FilledButton(
                  onPressed: end.isBefore(start)
                      ? null
                      : () {
                          final value = title.text.trim();
                          if (value.isEmpty) return;
                          Navigator.pop(context, (
                            title: value,
                            notes: notes.text,
                            location: location.text,
                            start: start.millisecondsSinceEpoch,
                            end: end.millisecondsSinceEpoch,
                            allDay: allDay,
                          ));
                        },
                  child: Text(l.actionSave),
                ),
              ],
            ),
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    title.dispose();
    notes.dispose();
    location.dispose();
    if (submitted == null || !mounted) return;
    final CloudCollectionEdit edit;
    if (event == null) {
      final id = widget.service.newCollectionEntityId();
      edit = CloudCollectionEdit.create(
        id,
        CloudCalendarEvent(
          id: id,
          title: submitted.title,
          notes: submitted.notes,
          startAtMs: submitted.start,
          endAtMs: submitted.end,
          allDay: submitted.allDay,
          location: submitted.location,
        ).toFields(),
      );
    } else {
      edit = CloudCollectionEdit.patch(event.id, {
        if (submitted.title != event.title) 'title': submitted.title,
        if (submitted.notes != event.notes) 'notes': submitted.notes,
        if (submitted.start != event.startAtMs) 'start': submitted.start,
        if (submitted.end != event.endAtMs) 'end': submitted.end,
        if (submitted.allDay != event.allDay) 'allDay': submitted.allDay,
        if (submitted.location != event.location)
          'location': submitted.location,
      });
    }
    if (edit.kind == CloudCollectionEditKind.patch && edit.fields.isEmpty) {
      return;
    }
    await _mutate(
      () => widget.service.appendCollectionEdits(widget.documentId, [
        edit,
      ], parentOperationIds: state.snapshot.headOperationIds),
    );
  }

  Future<void> _delete(String id, String title) async {
    final state = _state;
    if (state == null || !state.canEdit || _busy) return;
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.cloudCollectionDeleteTitle(title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cloudCollectionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(
      () => widget.service.appendCollectionEdits(widget.documentId, [
        CloudCollectionEdit.delete(id),
      ], parentOperationIds: state.snapshot.headOperationIds),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final state = _state;
    if (_loading) {
      return const SafeArea(child: Center(child: CircularProgressIndicator()));
    }
    if (state == null) {
      return SafeArea(child: Center(child: Text(l.cloudCollectionFailed)));
    }
    final tasks = [...state.tasks]
      ..sort((a, b) {
        final byDone = a.completed == b.completed ? 0 : (a.completed ? 1 : -1);
        return byDone != 0 ? byDone : a.position.compareTo(b.position);
      });
    final events = [...state.events]
      ..sort((a, b) => a.startAtMs.compareTo(b.startAtMs));
    final isTasks = state.kind == CloudDocumentKind.taskList;
    return SafeArea(
      child: Column(
        children: [
          ListTile(
            leading: widget.onClose == null
                ? Icon(isTasks ? Icons.task_alt : Icons.calendar_month)
                : IconButton(
                    key: const ValueKey('cloud-collection-close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: _busy ? null : widget.onClose,
                    icon: const Icon(Icons.arrow_back),
                  ),
            title: Text(isTasks ? l.cloudTasksTitle : l.cloudCalendarTitle),
            subtitle: Text(
              state.canEdit
                  ? l.cloudCollectionCollaborative
                  : l.cloudRichReadOnly,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (widget.onManage != null)
                  IconButton(
                    tooltip: l.cloudRichManage,
                    onPressed: _busy ? null : widget.onManage,
                    icon: const Icon(Icons.group_outlined),
                  ),
              ],
            ),
          ),
          if (state.snapshot.invalidOperationIds.isNotEmpty)
            MaterialBanner(
              content: Text(l.cloudCollectionInvalid),
              leading: const Icon(Icons.gpp_bad_outlined),
              actions: [
                TextButton(
                  onPressed: ScaffoldMessenger.of(
                    context,
                  ).hideCurrentMaterialBanner,
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          const Divider(height: 1),
          Expanded(
            child: isTasks
                ? _TaskList(
                    tasks: tasks,
                    editable: state.canEdit && !_busy,
                    onToggle: _toggleTask,
                    onEdit: _editTask,
                    onDelete: (task) => _delete(task.id, task.title),
                  )
                : _EventList(
                    events: events,
                    editable: state.canEdit && !_busy,
                    onEdit: _editEvent,
                    onDelete: (event) => _delete(event.id, event.title),
                  ),
          ),
          if (state.canEdit)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: ValueKey(isTasks ? 'cloud-task-add' : 'cloud-event-add'),
                  onPressed: _busy
                      ? null
                      : isTasks
                      ? _editTask
                      : _editEvent,
                  icon: const Icon(Icons.add),
                  label: Text(isTasks ? l.cloudTaskAdd : l.cloudEventAdd),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.editable,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final List<CloudTask> tasks;
  final bool editable;
  final Future<void> Function(CloudTask task, bool completed) onToggle;
  final Future<void> Function(CloudTask task) onEdit;
  final Future<void> Function(CloudTask task) onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    if (tasks.isEmpty) return Center(child: Text(l.cloudCollectionEmptyTasks));
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (context, index) {
        final task = tasks[index];
        return ListTile(
          key: ValueKey('cloud-task-${task.id}'),
          leading: Checkbox(
            value: task.completed,
            onChanged: editable
                ? (value) => onToggle(task, value ?? false)
                : null,
          ),
          title: Text(
            task.title,
            style: task.completed
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
          ),
          subtitle: Text(
            [
              if (task.dueAtMs != null)
                _formatDate(
                  context,
                  DateTime.fromMillisecondsSinceEpoch(task.dueAtMs!),
                ),
              if (task.notes.isNotEmpty) task.notes,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: editable
              ? PopupMenuButton<String>(
                  onSelected: (action) =>
                      action == 'edit' ? onEdit(task) : onDelete(task),
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'edit', child: Text(l.cloudTaskEdit)),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l.cloudCollectionDelete),
                    ),
                  ],
                )
              : null,
          onTap: editable ? () => onEdit(task) : null,
        );
      },
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({
    required this.events,
    required this.editable,
    required this.onEdit,
    required this.onDelete,
  });

  final List<CloudCalendarEvent> events;
  final bool editable;
  final Future<void> Function(CloudCalendarEvent event) onEdit;
  final Future<void> Function(CloudCalendarEvent event) onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    if (events.isEmpty) {
      return Center(child: Text(l.cloudCollectionEmptyEvents));
    }
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        final start = DateTime.fromMillisecondsSinceEpoch(event.startAtMs);
        final end = DateTime.fromMillisecondsSinceEpoch(event.endAtMs);
        return ListTile(
          key: ValueKey('cloud-event-${event.id}'),
          leading: const Icon(Icons.event_outlined),
          title: Text(event.title),
          subtitle: Text(
            [
              '${_formatDateTime(context, start, event.allDay)} – ${_formatDateTime(context, end, event.allDay)}',
              if (event.location.isNotEmpty) event.location,
              if (event.notes.isNotEmpty) event.notes,
            ].join('\n'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: editable
              ? PopupMenuButton<String>(
                  onSelected: (action) =>
                      action == 'edit' ? onEdit(event) : onDelete(event),
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'edit', child: Text(l.cloudEventEdit)),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l.cloudCollectionDelete),
                    ),
                  ],
                )
              : null,
          onTap: editable ? () => onEdit(event) : null,
        );
      },
    );
  }
}

Future<DateTime?> _pickDateTime(
  BuildContext context,
  DateTime initial, {
  required bool allDay,
}) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(1970),
    lastDate: DateTime(2200),
  );
  if (date == null || !context.mounted) return null;
  if (allDay) return DateTime(date.year, date.month, date.day);
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

String _formatDate(BuildContext context, DateTime value) =>
    MaterialLocalizations.of(context).formatMediumDate(value);

String _formatDateTime(BuildContext context, DateTime value, bool allDay) {
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatMediumDate(value);
  return allDay
      ? date
      : '$date ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
}
