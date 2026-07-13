import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud_collection_crdt.dart';
import 'package:xveil/domain/cloud_document.dart';

String _id(int value) => value.toRadixString(16).padLeft(64, '0');

NodeId _author(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

CloudDocumentOperation _operation(
  int id, {
  required CloudDocumentKind kind,
  List<int> parents = const [],
  int author = 1,
  int epoch = 0,
}) => CloudDocumentOperation(
  documentId: NodeId(Uint8List(32)),
  membershipEpoch: epoch,
  author: _author(author),
  seq: id,
  prevAuthorHash: '',
  operationId: _id(id),
  parentOperationIds: parents.map(_id).toList()..sort(),
  opType: cloudCollectionOperationType(kind)!,
  payloadHash: _id(9000 + id),
  createdAtMs: id,
  authorPubKey: Uint8List(32),
  signature: Uint8List(64),
);

CloudTask _task(
  int id, {
  String title = 'Task',
  String notes = '',
  bool completed = false,
  int? dueAtMs,
  int position = 0,
}) => CloudTask(
  id: _id(id),
  title: title,
  notes: notes,
  completed: completed,
  dueAtMs: dueAtMs,
  position: position,
);

CloudCalendarEvent _event(
  int id, {
  String title = 'Event',
  String notes = '',
  int startAtMs = 1000,
  int endAtMs = 2000,
  bool allDay = false,
  String location = '',
}) => CloudCalendarEvent(
  id: _id(id),
  title: title,
  notes: notes,
  startAtMs: startAtMs,
  endAtMs: endAtMs,
  allDay: allDay,
  location: location,
);

Map<String, Uint8List> _payloads(Map<int, CloudCollectionEdit> edits) => {
  for (final entry in edits.entries) _id(entry.key): entry.value.encode(),
};

CloudCollectionSnapshot _materialize(
  CloudDocumentKind kind,
  Iterable<CloudDocumentOperation> operations,
  Map<String, Uint8List> payloads,
) => materializeCloudCollection(
  documentKind: kind,
  owner: _author(1),
  operations: operations,
  cleartextByOperationId: payloads,
);

void main() {
  test('task and calendar codecs are strict and kind-bound', () {
    final task = _task(10, title: 'Ship', dueAtMs: 42);
    final taskEdit = CloudCollectionEdit.create(task.id, task.toFields());
    final decodedTask = CloudCollectionEdit.decode(
      taskEdit.encode(),
      documentKind: CloudDocumentKind.taskList,
    );
    expect(decodedTask?.kind, CloudCollectionEditKind.create);
    expect(
      CloudTask.fromRow(
        CloudCollectionRow(id: task.id, fields: decodedTask!.fields),
      )?.title,
      'Ship',
    );
    expect(
      CloudCollectionEdit.decode(
        taskEdit.encode(),
        documentKind: CloudDocumentKind.calendar,
      ),
      isNull,
    );

    final event = _event(11, title: 'Meet', location: 'Room');
    final eventEdit = CloudCollectionEdit.create(event.id, event.toFields());
    expect(
      CloudCalendarEvent.fromRow(
        CloudCollectionRow(
          id: event.id,
          fields: CloudCollectionEdit.decode(
            eventEdit.encode(),
            documentKind: CloudDocumentKind.calendar,
          )!.fields,
        ),
      )?.location,
      'Room',
    );

    expect(
      CloudCollectionEdit.decode(
        Uint8List.fromList(
          utf8.encode(
            '{"v":1,"k":"patch","id":"${_id(10)}","f":{"unknown":1}}',
          ),
        ),
        documentKind: CloudDocumentKind.taskList,
      ),
      isNull,
    );
    expect(
      CloudCollectionEdit.decode(
        Uint8List.fromList(
          utf8.encode(
            '{"v":1,"k":"create","id":"${_id(10)}","f":{"title":"missing fields"}}',
          ),
        ),
        documentKind: CloudDocumentKind.taskList,
      ),
      isNull,
    );
    expect(
      CloudCollectionEdit.decode(
        CloudCollectionEdit.create(
          _id(12),
          _event(12, startAtMs: 2000, endAtMs: 1000).toFields(),
        ).encode(),
        documentKind: CloudDocumentKind.calendar,
      ),
      isNull,
    );
    expect(
      CloudCollectionEdit.decode(
        Uint8List(1024 * 1024 + 1),
        documentKind: CloudDocumentKind.taskList,
      ),
      isNull,
    );
  });

  test('field-level task patches converge independent of delivery order', () {
    final create = _operation(1, kind: CloudDocumentKind.taskList);
    final rename = _operation(
      2,
      kind: CloudDocumentKind.taskList,
      parents: [1],
      author: 2,
    );
    final complete = _operation(
      3,
      kind: CloudDocumentKind.taskList,
      parents: [1],
      author: 3,
    );
    final payloads = _payloads({
      1: CloudCollectionEdit.create(_id(20), _task(20).toFields()),
      2: CloudCollectionEdit.patch(_id(20), {'title': 'Renamed'}),
      3: CloudCollectionEdit.patch(_id(20), {'completed': true}),
    });

    final first = _materialize(CloudDocumentKind.taskList, [
      create,
      rename,
      complete,
    ], payloads);
    final second = _materialize(CloudDocumentKind.taskList, [
      complete,
      create,
      rename,
    ], payloads);
    final firstTask = CloudTask.fromRow(first.rows.single)!;
    final secondTask = CloudTask.fromRow(second.rows.single)!;
    expect(firstTask.title, 'Renamed');
    expect(firstTask.completed, isTrue);
    expect(secondTask.title, firstTask.title);
    expect(secondTask.completed, firstTask.completed);
    expect(first.headOperationIds, [_id(2), _id(3)]);
  });

  test('concurrent delete wins and a causal create explicitly restores', () {
    final create = _operation(1, kind: CloudDocumentKind.taskList);
    final patch = _operation(
      2,
      kind: CloudDocumentKind.taskList,
      parents: [1],
      author: 2,
    );
    final remove = _operation(
      3,
      kind: CloudDocumentKind.taskList,
      parents: [1],
    );
    final restore = _operation(
      4,
      kind: CloudDocumentKind.taskList,
      parents: [2, 3],
      author: 2,
    );
    final basePayloads = _payloads({
      1: CloudCollectionEdit.create(_id(20), _task(20).toFields()),
      2: CloudCollectionEdit.patch(_id(20), {'title': 'Concurrent'}),
      3: CloudCollectionEdit.delete(_id(20)),
    });
    expect(
      _materialize(CloudDocumentKind.taskList, [
        patch,
        remove,
        create,
      ], basePayloads).rows,
      isEmpty,
    );

    final restored = _materialize(
      CloudDocumentKind.taskList,
      [restore, remove, patch, create],
      {
        ...basePayloads,
        _id(4): CloudCollectionEdit.create(
          _id(20),
          _task(20, title: 'Restored').toFields(),
        ).encode(),
      },
    );
    expect(CloudTask.fromRow(restored.rows.single)!.title, 'Restored');
  });

  test('owner checkpoint replaces old epoch without historical cleartext', () {
    final historical = _operation(1, kind: CloudDocumentKind.calendar);
    final checkpoint = _operation(
      2,
      kind: CloudDocumentKind.calendar,
      epoch: 1,
    );
    final snapshot = _materialize(
      CloudDocumentKind.calendar,
      [historical, checkpoint],
      _payloads({
        2: CloudCollectionEdit.checkpoint([_event(30).toRow()]),
      }),
    );
    expect(snapshot.rows.single.id, _id(30));
    expect(snapshot.unavailableOperationIds, [_id(1)]);
  });

  test('editor checkpoint is invalid and cannot replace owner state', () {
    final create = _operation(1, kind: CloudDocumentKind.taskList);
    final forged = _operation(
      2,
      kind: CloudDocumentKind.taskList,
      parents: [1],
      author: 2,
      epoch: 1,
    );
    final snapshot = _materialize(
      CloudDocumentKind.taskList,
      [forged, create],
      _payloads({
        1: CloudCollectionEdit.create(_id(20), _task(20).toFields()),
        2: CloudCollectionEdit.checkpoint([_task(21, title: 'Forged').toRow()]),
      }),
    );
    expect(snapshot.rows.single.id, _id(20));
    expect(snapshot.invalidOperationIds, [_id(2)]);
  });

  test('invalid calendar interval remains hidden until causally repaired', () {
    final create = _operation(1, kind: CloudDocumentKind.calendar);
    final invalid = _operation(
      2,
      kind: CloudDocumentKind.calendar,
      parents: [1],
    );
    final repair = _operation(
      3,
      kind: CloudDocumentKind.calendar,
      parents: [2],
    );
    final payloads = _payloads({
      1: CloudCollectionEdit.create(_id(30), _event(30).toFields()),
      2: CloudCollectionEdit.patch(_id(30), {'end': 500}),
      3: CloudCollectionEdit.patch(_id(30), {'end': 3000}),
    });
    expect(
      _materialize(CloudDocumentKind.calendar, [
        create,
        invalid,
      ], payloads).rows,
      isEmpty,
    );
    expect(
      CloudCalendarEvent.fromRow(
        _materialize(CloudDocumentKind.calendar, [
          repair,
          invalid,
          create,
        ], payloads).rows.single,
      )!.endAtMs,
      3000,
    );
  });
}
