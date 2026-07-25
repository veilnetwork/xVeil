import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'cloud_document.dart';

const cloudTaskListCodecV1 = 'xveil.tasks.map.v1';
const cloudCalendarCodecV1 = 'xveil.calendar.map.v1';
const cloudFileCollectionCodecV1 = 'xveil.files.map.v1';
const cloudTaskOperationType = 'tasks.v1';
const cloudCalendarOperationType = 'calendar.v1';
const cloudFileCollectionOperationType = 'files.v1';

const int _maxRows = 4096;
const int _maxPayloadBytes = 1024 * 1024;
const int _maxTitleBytes = 512;
const int _maxNotesBytes = 8192;
const int _maxLocationBytes = 1024;
final RegExp _entityIdPattern = RegExp(r'^[0-9a-f]{64}$');

String? cloudCollectionCodec(CloudDocumentKind kind) => switch (kind) {
  CloudDocumentKind.taskList => cloudTaskListCodecV1,
  CloudDocumentKind.calendar => cloudCalendarCodecV1,
  CloudDocumentKind.fileCollection => cloudFileCollectionCodecV1,
  CloudDocumentKind.note => null,
};

String? cloudCollectionOperationType(CloudDocumentKind kind) => switch (kind) {
  CloudDocumentKind.taskList => cloudTaskOperationType,
  CloudDocumentKind.calendar => cloudCalendarOperationType,
  CloudDocumentKind.fileCollection => cloudFileCollectionOperationType,
  CloudDocumentKind.note => null,
};

enum CloudCollectionEditKind { create, patch, delete, checkpoint, merge }

class CloudCollectionRow {
  CloudCollectionRow({required this.id, required Map<String, Object?> fields})
    : fields = Map.unmodifiable(fields);

  final String id;
  final Map<String, Object?> fields;
}

/// Strict, bounded cleartext operation encrypted by the document epoch layer.
class CloudCollectionEdit {
  CloudCollectionEdit._({
    required this.kind,
    this.entityId,
    Map<String, Object?> fields = const {},
    List<CloudCollectionRow> rows = const [],
  }) : fields = Map.unmodifiable(fields),
       rows = List.unmodifiable(rows);

  factory CloudCollectionEdit.create(
    String entityId,
    Map<String, Object?> fields,
  ) => CloudCollectionEdit._(
    kind: CloudCollectionEditKind.create,
    entityId: entityId,
    fields: fields,
  );

  factory CloudCollectionEdit.patch(
    String entityId,
    Map<String, Object?> fields,
  ) => CloudCollectionEdit._(
    kind: CloudCollectionEditKind.patch,
    entityId: entityId,
    fields: fields,
  );

  factory CloudCollectionEdit.delete(String entityId) => CloudCollectionEdit._(
    kind: CloudCollectionEditKind.delete,
    entityId: entityId,
  );

  factory CloudCollectionEdit.checkpoint(Iterable<CloudCollectionRow> rows) =>
      CloudCollectionEdit._(
        kind: CloudCollectionEditKind.checkpoint,
        rows: rows.toList(),
      );

  CloudCollectionEdit.merge() : this._(kind: CloudCollectionEditKind.merge);

  final CloudCollectionEditKind kind;
  final String? entityId;
  final Map<String, Object?> fields;
  final List<CloudCollectionRow> rows;

  Uint8List encode() {
    final value = <String, Object?>{'v': 1, 'k': kind.name};
    switch (kind) {
      case CloudCollectionEditKind.create:
      case CloudCollectionEditKind.patch:
        value['id'] = entityId;
        value['f'] = fields;
        break;
      case CloudCollectionEditKind.delete:
        value['id'] = entityId;
        break;
      case CloudCollectionEditKind.checkpoint:
        final ordered = [...rows]..sort((a, b) => a.id.compareTo(b.id));
        value['rows'] = [
          for (final row in ordered) {'id': row.id, 'f': row.fields},
        ];
        break;
      case CloudCollectionEditKind.merge:
        break;
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(value)));
  }

  static CloudCollectionEdit? decode(
    Uint8List bytes, {
    required CloudDocumentKind documentKind,
  }) {
    if (documentKind == CloudDocumentKind.note ||
        bytes.isEmpty ||
        bytes.length > _maxPayloadBytes) {
      return null;
    }
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map || value['v'] != 1 || value['k'] is! String) {
        return null;
      }
      final kind = CloudCollectionEditKind.values
          .where((candidate) => candidate.name == value['k'])
          .firstOrNull;
      if (kind == null) return null;
      switch (kind) {
        case CloudCollectionEditKind.create:
        case CloudCollectionEditKind.patch:
          if (value.length != 4 || !_validEntityId(value['id'])) return null;
          final fields = _parseFields(
            value['f'],
            documentKind,
            complete: kind == CloudCollectionEditKind.create,
          );
          if (fields == null || fields.isEmpty) return null;
          return kind == CloudCollectionEditKind.create
              ? CloudCollectionEdit.create(value['id'] as String, fields)
              : CloudCollectionEdit.patch(value['id'] as String, fields);
        case CloudCollectionEditKind.delete:
          return value.length == 3 && _validEntityId(value['id'])
              ? CloudCollectionEdit.delete(value['id'] as String)
              : null;
        case CloudCollectionEditKind.checkpoint:
          if (value.length != 3 || value['rows'] is! List) return null;
          final rawRows = value['rows'] as List;
          if (rawRows.length > _maxRows) return null;
          final rows = <CloudCollectionRow>[];
          var priorId = '';
          for (final raw in rawRows) {
            if (raw is! Map || raw.length != 2 || !_validEntityId(raw['id'])) {
              return null;
            }
            final id = raw['id'] as String;
            if (id.compareTo(priorId) <= 0) return null;
            final fields = _parseFields(raw['f'], documentKind, complete: true);
            if (fields == null) return null;
            rows.add(CloudCollectionRow(id: id, fields: fields));
            priorId = id;
          }
          return CloudCollectionEdit.checkpoint(rows);
        case CloudCollectionEditKind.merge:
          return value.length == 2 ? CloudCollectionEdit.merge() : null;
      }
    } catch (_) {
      return null;
    }
  }
}

class CloudTask {
  const CloudTask({
    required this.id,
    required this.title,
    required this.notes,
    required this.completed,
    required this.position,
    this.dueAtMs,
  });

  final String id;
  final String title;
  final String notes;
  final bool completed;
  final int? dueAtMs;
  final int position;

  Map<String, Object?> toFields() => {
    'title': title,
    'notes': notes,
    'completed': completed,
    'due': dueAtMs,
    'position': position,
  };

  CloudCollectionRow toRow() => CloudCollectionRow(id: id, fields: toFields());

  static CloudTask? fromRow(CloudCollectionRow row) {
    final fields = _parseFields(
      row.fields,
      CloudDocumentKind.taskList,
      complete: true,
    );
    if (fields == null) return null;
    return CloudTask(
      id: row.id,
      title: fields['title']! as String,
      notes: fields['notes']! as String,
      completed: fields['completed']! as bool,
      dueAtMs: fields['due'] as int?,
      position: fields['position']! as int,
    );
  }
}

class CloudCalendarEvent {
  const CloudCalendarEvent({
    required this.id,
    required this.title,
    required this.notes,
    required this.startAtMs,
    required this.endAtMs,
    required this.allDay,
    required this.location,
  });

  final String id;
  final String title;
  final String notes;
  final int startAtMs;
  final int endAtMs;
  final bool allDay;
  final String location;

  Map<String, Object?> toFields() => {
    'title': title,
    'notes': notes,
    'start': startAtMs,
    'end': endAtMs,
    'allDay': allDay,
    'location': location,
  };

  CloudCollectionRow toRow() => CloudCollectionRow(id: id, fields: toFields());

  static CloudCalendarEvent? fromRow(CloudCollectionRow row) {
    final fields = _parseFields(
      row.fields,
      CloudDocumentKind.calendar,
      complete: true,
    );
    if (fields == null) return null;
    final start = fields['start']! as int;
    final end = fields['end']! as int;
    if (end < start) return null;
    return CloudCalendarEvent(
      id: row.id,
      title: fields['title']! as String,
      notes: fields['notes']! as String,
      startAtMs: start,
      endAtMs: end,
      allDay: fields['allDay']! as bool,
      location: fields['location']! as String,
    );
  }
}

/// One file reference inside a shared (ACL) folder. [contentId] addresses the
/// immutable bytes; the entry travels as a bounded CRDT row, and the bytes are
/// pulled by members through the separate epoch-gated content path. [path] is
/// the file's folder position INSIDE the shared folder ('' = its root).
class CloudFileEntry {
  const CloudFileEntry({
    required this.id,
    required this.name,
    required this.contentId,
    required this.size,
    this.mime,
    this.path = '',
  });

  final String id;
  final String name;
  final String contentId;
  final int size;
  final String? mime;
  final String path;

  Map<String, Object?> toFields() => {
    'name': name,
    'cid': contentId,
    'size': size,
    if (mime != null) 'mime': mime,
    'path': path,
  };

  CloudCollectionRow toRow() => CloudCollectionRow(id: id, fields: toFields());

  static CloudFileEntry? fromRow(CloudCollectionRow row) {
    final fields = _parseFields(
      row.fields,
      CloudDocumentKind.fileCollection,
      complete: true,
    );
    if (fields == null) return null;
    return CloudFileEntry(
      id: row.id,
      name: fields['name']! as String,
      contentId: fields['cid']! as String,
      size: fields['size']! as int,
      mime: fields['mime'] as String?,
      path: (fields['path'] as String?) ?? '',
    );
  }
}

class CloudCollectionSnapshot {
  const CloudCollectionSnapshot({
    required this.rows,
    required this.headOperationIds,
    required this.invalidOperationIds,
    required this.unavailableOperationIds,
  });

  final List<CloudCollectionRow> rows;
  final List<String> headOperationIds;
  final List<String> invalidOperationIds;
  final List<String> unavailableOperationIds;
}

class _Register {
  _Register(this.value, this.operationId);
  Object? value;
  String operationId;
}

class _EntityState {
  final Map<String, _Register> fields = {};
  _Register? alive;
}

CloudCollectionSnapshot materializeCloudCollection({
  required CloudDocumentKind documentKind,
  required NodeId owner,
  required Iterable<CloudDocumentOperation> operations,
  required Map<String, Uint8List> cleartextByOperationId,
}) {
  final expectedType = cloudCollectionOperationType(documentKind);
  if (expectedType == null) {
    return const CloudCollectionSnapshot(
      rows: [],
      headOperationIds: [],
      invalidOperationIds: [],
      unavailableOperationIds: [],
    );
  }
  final relevant = <String, CloudDocumentOperation>{};
  for (final operation in operations) {
    if (operation.opType == expectedType &&
        _entityIdPattern.hasMatch(operation.operationId)) {
      relevant[operation.operationId] = operation;
    }
  }
  final ordered = _topologicalOperations(relevant);
  final pastCache = <String, Set<String>>{};
  Set<String> causalPast(String operationId) =>
      pastCache.putIfAbsent(operationId, () {
        final seen = <String>{};
        final pending = <String>[...?relevant[operationId]?.parentOperationIds];
        while (pending.isNotEmpty) {
          final candidate = pending.removeLast();
          if (!seen.add(candidate)) continue;
          pending.addAll(relevant[candidate]?.parentOperationIds ?? const []);
        }
        return seen;
      });

  final decoded = <String, CloudCollectionEdit>{};
  final invalid = <String>[];
  final unavailable = <String>[];
  for (final operation in ordered) {
    final bytes = cleartextByOperationId[operation.operationId];
    if (bytes == null) {
      unavailable.add(operation.operationId);
      continue;
    }
    final edit = CloudCollectionEdit.decode(bytes, documentKind: documentKind);
    if (edit == null ||
        (edit.kind == CloudCollectionEditKind.checkpoint &&
            operation.author != owner)) {
      invalid.add(operation.operationId);
      continue;
    }
    decoded[operation.operationId] = edit;
  }

  CloudDocumentOperation? checkpoint;
  for (final operation in ordered) {
    if (decoded[operation.operationId]?.kind !=
        CloudCollectionEditKind.checkpoint) {
      continue;
    }
    final prior = checkpoint;
    if (prior == null ||
        operation.membershipEpoch > prior.membershipEpoch ||
        (operation.membershipEpoch == prior.membershipEpoch &&
            operation.operationId.compareTo(prior.operationId) > 0)) {
      checkpoint = operation;
    }
  }

  final entities = <String, _EntityState>{};
  bool wins(
    String candidate,
    _Register? current, {
    required Object? value,
    bool alive = false,
  }) {
    if (current == null) return true;
    if (causalPast(candidate).contains(current.operationId)) return true;
    if (causalPast(current.operationId).contains(candidate)) return false;
    if (alive && value != current.value) {
      // Concurrent deletion wins over an edit/create. A later causal create is
      // an explicit restoration and passes the first branch above.
      return value == false;
    }
    return candidate.compareTo(current.operationId) > 0;
  }

  void applyFields(
    _EntityState entity,
    String operationId,
    Map<String, Object?> fields,
  ) {
    for (final entry in fields.entries) {
      final current = entity.fields[entry.key];
      if (wins(operationId, current, value: entry.value)) {
        entity.fields[entry.key] = _Register(entry.value, operationId);
      }
    }
  }

  final checkpointId = checkpoint?.operationId;
  if (checkpointId != null) {
    final edit = decoded[checkpointId]!;
    for (final row in edit.rows) {
      final entity = entities.putIfAbsent(row.id, _EntityState.new);
      entity.alive = _Register(true, checkpointId);
      applyFields(entity, checkpointId, row.fields);
    }
  }

  for (final operation in ordered) {
    final edit = decoded[operation.operationId];
    if (edit == null || operation.operationId == checkpointId) continue;
    if (checkpoint != null &&
        (operation.membershipEpoch < checkpoint.membershipEpoch ||
            causalPast(
              checkpoint.operationId,
            ).contains(operation.operationId))) {
      continue;
    }
    switch (edit.kind) {
      case CloudCollectionEditKind.create:
        final entity = entities.putIfAbsent(edit.entityId!, _EntityState.new);
        if (wins(
          operation.operationId,
          entity.alive,
          value: true,
          alive: true,
        )) {
          entity.alive = _Register(true, operation.operationId);
        }
        applyFields(entity, operation.operationId, edit.fields);
        break;
      case CloudCollectionEditKind.patch:
        final entity = entities.putIfAbsent(edit.entityId!, _EntityState.new);
        applyFields(entity, operation.operationId, edit.fields);
        break;
      case CloudCollectionEditKind.delete:
        final entity = entities.putIfAbsent(edit.entityId!, _EntityState.new);
        if (wins(
          operation.operationId,
          entity.alive,
          value: false,
          alive: true,
        )) {
          entity.alive = _Register(false, operation.operationId);
        }
        break;
      case CloudCollectionEditKind.checkpoint:
      case CloudCollectionEditKind.merge:
        break;
    }
  }

  final rows = <CloudCollectionRow>[];
  for (final entry in entities.entries) {
    if (entry.value.alive?.value != true) continue;
    final row = CloudCollectionRow(
      id: entry.key,
      fields: {
        for (final field in entry.value.fields.entries)
          field.key: field.value.value,
      },
    );
    final valid = switch (documentKind) {
      CloudDocumentKind.taskList => CloudTask.fromRow(row) != null,
      CloudDocumentKind.calendar => CloudCalendarEvent.fromRow(row) != null,
      CloudDocumentKind.fileCollection => CloudFileEntry.fromRow(row) != null,
      CloudDocumentKind.note => false,
    };
    if (valid) rows.add(row);
  }
  rows.sort((a, b) => a.id.compareTo(b.id));
  final parentIds = <String>{
    for (final operation in relevant.values) ...operation.parentOperationIds,
  };
  final heads = relevant.keys.where((id) => !parentIds.contains(id)).toList()
    ..sort();
  return CloudCollectionSnapshot(
    rows: List.unmodifiable(rows),
    headOperationIds: List.unmodifiable(heads),
    invalidOperationIds: List.unmodifiable(invalid..sort()),
    unavailableOperationIds: List.unmodifiable(unavailable..sort()),
  );
}

List<CloudDocumentOperation> _topologicalOperations(
  Map<String, CloudDocumentOperation> operations,
) {
  final remaining = Map<String, CloudDocumentOperation>.from(operations);
  final result = <CloudDocumentOperation>[];
  final emitted = <String>{};
  while (remaining.isNotEmpty) {
    final ready =
        remaining.values
            .where(
              (operation) => operation.parentOperationIds.every(
                (parent) =>
                    !operations.containsKey(parent) || emitted.contains(parent),
              ),
            )
            .toList()
          ..sort((a, b) => a.operationId.compareTo(b.operationId));
    if (ready.isEmpty) {
      result.addAll(
        remaining.values.toList()
          ..sort((a, b) => a.operationId.compareTo(b.operationId)),
      );
      break;
    }
    for (final operation in ready) {
      remaining.remove(operation.operationId);
      emitted.add(operation.operationId);
      result.add(operation);
    }
  }
  return result;
}

Map<String, Object?>? _parseFields(
  Object? value,
  CloudDocumentKind kind, {
  required bool complete,
}) {
  if (value is! Map || value.isEmpty) return null;
  final fields = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    fields[entry.key as String] = entry.value;
  }
  final allowed = switch (kind) {
    CloudDocumentKind.taskList => {
      'title',
      'notes',
      'completed',
      'due',
      'position',
    },
    CloudDocumentKind.calendar => {
      'title',
      'notes',
      'start',
      'end',
      'allDay',
      'location',
    },
    CloudDocumentKind.fileCollection => {'name', 'cid', 'size', 'mime', 'path'},
    CloudDocumentKind.note => const <String>{},
  };
  // task/calendar require every allowed field; fileCollection has optional
  // mime/path, so its completeness is enforced by [missingRequired] below.
  if (fields.keys.any((key) => !allowed.contains(key)) ||
      (complete &&
          kind != CloudDocumentKind.fileCollection &&
          fields.keys.toSet().length != allowed.length)) {
    return null;
  }
  final title = fields['title'];
  if (title != null && !_boundedNonEmpty(title, _maxTitleBytes)) return null;
  final notes = fields['notes'];
  if (notes != null && !_boundedString(notes, _maxNotesBytes)) return null;
  switch (kind) {
    case CloudDocumentKind.taskList:
      if (fields.containsKey('completed') && fields['completed'] is! bool) {
        return null;
      }
      final due = fields['due'];
      if (fields.containsKey('due') && due != null && !_nonNegativeInt(due)) {
        return null;
      }
      if (fields.containsKey('position') &&
          !_nonNegativeInt(fields['position'])) {
        return null;
      }
      break;
    case CloudDocumentKind.calendar:
      if (fields.containsKey('start') && !_nonNegativeInt(fields['start'])) {
        return null;
      }
      if (fields.containsKey('end') && !_nonNegativeInt(fields['end'])) {
        return null;
      }
      if (fields.containsKey('allDay') && fields['allDay'] is! bool) {
        return null;
      }
      final location = fields['location'];
      if (location != null && !_boundedString(location, _maxLocationBytes)) {
        return null;
      }
      if (complete &&
          fields['start'] is int &&
          fields['end'] is int &&
          (fields['end']! as int) < (fields['start']! as int)) {
        return null;
      }
      break;
    case CloudDocumentKind.fileCollection:
      final name = fields['name'];
      if (name != null && !_boundedNonEmpty(name, _maxTitleBytes)) return null;
      final cid = fields['cid'];
      if (cid != null && (cid is! String || !_entityIdPattern.hasMatch(cid))) {
        return null;
      }
      final size = fields['size'];
      if (size != null && !_nonNegativeInt(size)) return null;
      final mime = fields['mime'];
      if (mime != null && !_boundedString(mime, 255)) return null;
      final path = fields['path'];
      if (path != null && !_boundedString(path, _maxLocationBytes)) return null;
      break;
    case CloudDocumentKind.note:
      return null;
  }
  final missingRequired = switch (kind) {
    CloudDocumentKind.taskList =>
      fields['title'] == null ||
          fields['notes'] == null ||
          fields['completed'] == null ||
          fields['position'] == null,
    CloudDocumentKind.calendar =>
      fields['title'] == null ||
          fields['notes'] == null ||
          fields['start'] == null ||
          fields['end'] == null ||
          fields['allDay'] == null ||
          fields['location'] == null,
    CloudDocumentKind.fileCollection =>
      fields['name'] == null || fields['cid'] == null || fields['size'] == null,
    CloudDocumentKind.note => true,
  };
  if (complete && missingRequired) return null;
  return fields;
}

bool _validEntityId(Object? value) =>
    value is String && _entityIdPattern.hasMatch(value);

bool _boundedNonEmpty(Object? value, int maxBytes) =>
    value is String &&
    value.isNotEmpty &&
    utf8.encode(value).length <= maxBytes;

bool _boundedString(Object? value, int maxBytes) =>
    value is String && utf8.encode(value).length <= maxBytes;

bool _nonNegativeInt(Object? value) =>
    value is int && value >= 0 && value <= 8640000000000000;
