import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/device_sync.dart';

NodeId _id(int value) =>
    NodeId.fromHex(value.toRadixString(16).padLeft(64, '0'));

CloudItem _item({int modified = 10, int revision = 1}) => CloudItem(
  id: 'item_1',
  kind: CloudItemKind.file,
  name: 'notes.txt',
  contentId: List.filled(32, 'ab').join(),
  size: 42,
  mime: 'text/plain',
  createdAtMs: 5,
  modifiedAtMs: modified,
  revision: revision,
  deleted: false,
);

CloudItem _note(
  String byte, {
  int modified = 10,
  int revision = 1,
  List<String> parents = const [],
}) => CloudItem(
  id: 'note_1',
  kind: CloudItemKind.note,
  name: 'Note',
  contentId: List.filled(64, byte).join(),
  size: 4,
  mime: 'text/plain; charset=utf-8',
  createdAtMs: 5,
  modifiedAtMs: modified,
  revision: revision,
  deleted: false,
  parentContentIds: parents,
);

void main() {
  test('cloud item round-trips through the device-sync vocabulary', () {
    final item = _item();
    expect(CloudItem.fromEvent(item.toEvent())?.contentId, item.contentId);
    expect(CloudItem.fromEvent(item.toEvent())?.mime, 'text/plain');
  });

  test('newer tombstone wins and stale offline upsert cannot resurrect', () {
    final item = _item();
    final deleted = item.tombstone(20);
    final folded = foldCloudItems([deleted.toEvent(), item.toEvent()]);
    expect(folded[item.id]?.deleted, isTrue);
    expect(folded[item.id]?.revision, 2);
  });

  test('malformed and oversized index rows fail closed', () {
    final base = _item().toEvent();
    expect(
      CloudItem.fromEvent(
        DeviceSyncEvent(
          kind: base.kind,
          key: base.key,
          tsMs: base.tsMs,
          payload: {...base.payload, 'cid': 'not-a-hash'},
        ),
      ),
      isNull,
    );
    expect(
      CloudItem.fromEvent(
        DeviceSyncEvent(
          kind: base.kind,
          key: base.key,
          tsMs: base.tsMs,
          payload: {...base.payload, 'size': 1 << 51},
        ),
      ),
      isNull,
    );
  });

  test('concurrent parent-bound note edits remain as two DAG heads', () {
    final root = _note('a');
    final left = _note(
      'b',
      modified: 20,
      revision: 2,
      parents: [root.contentId!],
    );
    final right = _note(
      'c',
      modified: 30,
      revision: 2,
      parents: [root.contentId!],
    );
    final heads = foldCloudNoteHeads([
      root.toEvent(),
      right.toEvent(),
      left.toEvent(),
    ])['note_1']!;
    expect(heads.map((item) => item.contentId), {
      left.contentId,
      right.contentId,
    });
  });

  test('a higher revision naming every head collapses a note conflict', () {
    final root = _note('a');
    final left = _note(
      'b',
      modified: 20,
      revision: 2,
      parents: [root.contentId!],
    );
    final right = _note(
      'c',
      modified: 30,
      revision: 2,
      parents: [root.contentId!],
    );
    final merged = _note(
      'd',
      modified: 40,
      revision: 3,
      parents: [left.contentId!, right.contentId!],
    );
    final heads = foldCloudNoteHeads([
      root.toEvent(),
      left.toEvent(),
      right.toEvent(),
      merged.toEvent(),
    ])['note_1']!;
    expect(heads.single.contentId, merged.contentId);
  });

  test('legacy parentless notes retain their single LWW winner', () {
    final older = _note('a', modified: 10, revision: 1);
    final newer = _note('b', modified: 20, revision: 2);
    final heads = foldCloudNoteHeads([
      newer.toEvent(),
      older.toEvent(),
    ])['note_1']!;
    expect(heads.single.contentId, newer.contentId);
  });

  test(
    'note parents are strict, unique, bounded, and cannot self-reference',
    () {
      final note = _note('a');
      final event = note.toEvent();
      expect(
        CloudItem.fromEvent(
          DeviceSyncEvent(
            kind: event.kind,
            key: event.key,
            tsMs: event.tsMs,
            payload: {
              ...event.payload,
              'parents': [note.contentId],
            },
          ),
        ),
        isNull,
      );
      final parentA = List.filled(64, 'a').join();
      final parentB = List.filled(64, 'b').join();
      for (final parents in [
        [parentA, parentA],
        [parentB, parentA],
      ]) {
        expect(
          CloudItem.fromEvent(
            DeviceSyncEvent(
              kind: event.kind,
              key: event.key,
              tsMs: event.tsMs,
              payload: {...event.payload, 'parents': parents},
            ),
          ),
          isNull,
        );
      }
      expect(
        CloudItem.fromEvent(
          DeviceSyncEvent(
            kind: event.kind,
            key: event.key,
            tsMs: event.tsMs,
            payload: {
              ...event.payload,
              'parents': List.filled(CloudItem.maxNoteParents + 1, 'bad'),
            },
          ),
        ),
        isNull,
      );
    },
  );

  test('replica claim is bound to its signed message author', () {
    final claim = CloudReplicaClaim(
      itemId: 'item_1',
      deviceId: _id(1),
      contentId: List.filled(32, 'cd').join(),
      present: true,
      verifiedAtMs: 100,
      size: 7,
    );
    expect(
      CloudReplicaClaim.fromEvent(claim.toEvent(), author: _id(1)),
      isNotNull,
    );
    expect(
      CloudReplicaClaim.fromEvent(claim.toEvent(), author: _id(2)),
      isNull,
    );
    final event = claim.toEvent();
    expect(
      CloudReplicaClaim.fromEvent(
        DeviceSyncEvent(
          kind: event.kind,
          key:
              '${claim.itemId}|${claim.deviceId.hex}|'
              '${List.filled(64, 'a').join()}',
          tsMs: event.tsMs,
          payload: event.payload,
        ),
        author: _id(1),
      ),
      isNull,
    );
    expect(
      CloudReplicaClaim.fromEvent(
        DeviceSyncEvent(
          kind: event.kind,
          key: '${claim.itemId}|${claim.deviceId.hex}',
          tsMs: event.tsMs,
          payload: event.payload,
        ),
        author: _id(1),
      ),
      isNotNull,
      reason: 'legacy two-part claim keys remain readable',
    );
  });

  test('replica fold keeps newest valid claim and ignores forged author', () {
    final first = CloudReplicaClaim(
      itemId: 'item_1',
      deviceId: _id(1),
      contentId: List.filled(32, 'ef').join(),
      present: true,
      verifiedAtMs: 10,
      size: 9,
    );
    final gone = CloudReplicaClaim(
      itemId: 'item_1',
      deviceId: _id(1),
      contentId: List.filled(32, 'ef').join(),
      present: false,
      verifiedAtMs: 20,
      size: 9,
    );
    final folded = foldCloudReplicaClaims([
      (event: first.toEvent(), author: _id(1)),
      (event: gone.toEvent(), author: _id(1)),
      (event: first.toEvent(), author: _id(2)),
    ]);
    expect(folded[first.key]?.present, isFalse);
  });

  test('cloud folder round-trips and rejects malformed rows fail-closed', () {
    final folder = CloudFolder(
      id: 'folder_1',
      name: 'Работа',
      createdAtMs: 5,
      modifiedAtMs: 10,
      revision: 1,
      deleted: false,
    );
    final parsed = CloudFolder.fromEvent(folder.toEvent());
    expect(parsed?.name, 'Работа');
    expect(parsed?.createdAtMs, 5);
    expect(parsed?.revision, 1);
    final event = folder.toEvent();
    for (final payload in [
      {...event.payload, 'name': ''},
      {...event.payload, 'name': 'x' * 513},
      {...event.payload, 'rev': 0},
      {...event.payload, 'created': 'nope'},
    ]) {
      expect(
        CloudFolder.fromEvent(
          DeviceSyncEvent(
            kind: event.kind,
            key: event.key,
            tsMs: event.tsMs,
            payload: payload,
          ),
        ),
        isNull,
      );
    }
    expect(
      CloudFolder.fromEvent(
        DeviceSyncEvent(
          kind: event.kind,
          key: 'bad id!',
          tsMs: event.tsMs,
          payload: event.payload,
        ),
      ),
      isNull,
    );
  });

  test('folder fold is LWW and a tombstone absorbs stale offline upserts', () {
    final folder = CloudFolder(
      id: 'folder_1',
      name: 'Old',
      createdAtMs: 5,
      modifiedAtMs: 10,
      revision: 1,
      deleted: false,
    );
    final renamed = CloudFolder(
      id: 'folder_1',
      name: 'New',
      createdAtMs: 5,
      modifiedAtMs: 20,
      revision: 2,
      deleted: false,
    );
    expect(
      foldCloudFolders([renamed.toEvent(), folder.toEvent()])['folder_1']?.name,
      'New',
      reason: 'order-independent newest-wins',
    );
    final deleted = renamed.tombstone(30);
    final folded = foldCloudFolders([
      deleted.toEvent(),
      folder.toEvent(),
      renamed.toEvent(),
    ]);
    expect(folded['folder_1']?.deleted, isTrue);
  });

  test('item folder assignment survives the wire and stays fail-closed', () {
    final inFolder = _item().movedToFolder('folder_1', 30);
    final parsed = CloudItem.fromEvent(inFolder.toEvent());
    expect(parsed?.folderId, 'folder_1');
    expect(parsed?.revision, _item().revision, reason: 'metadata-only move');
    final rootAgain = inFolder.movedToFolder(null, 40);
    expect(CloudItem.fromEvent(rootAgain.toEvent())?.folderId, isNull);
    final event = inFolder.toEvent();
    expect(
      CloudItem.fromEvent(
        DeviceSyncEvent(
          kind: event.kind,
          key: event.key,
          tsMs: event.tsMs,
          payload: {...event.payload, 'folder': 'bad id!'},
        ),
      ),
      isNull,
    );
    // Legacy rows without the key parse to the root.
    expect(CloudItem.fromEvent(_item().toEvent())?.folderId, isNull);
  });

  test('a folder move wins the LWW row without disturbing note DAG heads', () {
    final root = _note('a');
    final edit = _note(
      'b',
      modified: 20,
      revision: 2,
      parents: [root.contentId!],
    );
    final moved = edit.movedToFolder('folder_1', 30);
    final events = [root.toEvent(), edit.toEvent(), moved.toEvent()];
    final winner = foldCloudItems(events)['note_1']!;
    expect(winner.folderId, 'folder_1');
    expect(winner.contentId, edit.contentId);
    final heads = foldCloudNoteHeads(events)['note_1']!;
    expect(heads.single.contentId, edit.contentId);
  });

  test('replication profile is local, bounded and defaults index-only', () {
    expect(
      CloudReplicationProfile.decode(null).mode,
      CloudReplicationMode.indexOnly,
    );
    final profile = CloudReplicationProfile(
      mode: CloudReplicationMode.selected,
      selectedItemIds: {'item_1'},
    );
    final decoded = CloudReplicationProfile.decode(profile.encode());
    expect(decoded.mode, CloudReplicationMode.selected);
    expect(decoded.wants(_item()), isTrue);
    expect(decoded.wants(_item().tombstone(30)), isFalse);
  });
}
