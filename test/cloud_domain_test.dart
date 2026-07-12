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
