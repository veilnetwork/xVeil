import 'dart:convert';

import '../core/ids.dart';
import 'device_sync.dart';

enum CloudItemKind { file, note, task, calendarEvent }

/// One logical object in the personal-cloud index. The object id survives a
/// content update; [contentId] addresses the current immutable bytes. Deletes
/// are LWW tombstones so an offline device cannot resurrect an older version.
class CloudItem {
  const CloudItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.contentId,
    required this.size,
    required this.createdAtMs,
    required this.modifiedAtMs,
    required this.revision,
    required this.deleted,
    this.mime,
  });

  final String id;
  final CloudItemKind kind;
  final String name;
  final String? contentId;
  final int size;
  final String? mime;
  final int createdAtMs;
  final int modifiedAtMs;
  final int revision;
  final bool deleted;

  DeviceSyncEvent toEvent() => DeviceSyncEvent(
    kind: DeviceSyncKind.cloudEntry,
    key: id,
    tsMs: modifiedAtMs,
    payload: deleted
        ? {'del': true, 'rev': revision}
        : {
            'type': kind.name,
            'name': name,
            'cid': contentId,
            'size': size,
            'created': createdAtMs,
            'rev': revision,
            if (mime != null) 'mime': mime,
          },
  );

  CloudItem tombstone(int atMs) => CloudItem(
    id: id,
    kind: kind,
    name: '',
    contentId: null,
    size: 0,
    createdAtMs: createdAtMs,
    modifiedAtMs: atMs,
    revision: revision + 1,
    deleted: true,
  );

  static CloudItem? fromEvent(DeviceSyncEvent event) {
    if (event.kind != DeviceSyncKind.cloudEntry || !_validId(event.key)) {
      return null;
    }
    final p = event.payload;
    final revision = p['rev'];
    if (revision is! int || revision < 1) return null;
    if (p['del'] == true) {
      return CloudItem(
        id: event.key,
        kind: CloudItemKind.file,
        name: '',
        contentId: null,
        size: 0,
        createdAtMs: event.tsMs,
        modifiedAtMs: event.tsMs,
        revision: revision,
        deleted: true,
      );
    }
    CloudItemKind? kind;
    for (final value in CloudItemKind.values) {
      if (value.name == p['type']) kind = value;
    }
    final name = p['name'];
    final cid = p['cid'];
    final size = p['size'];
    final created = p['created'];
    final mime = p['mime'];
    if (kind == null ||
        name is! String ||
        name.isEmpty ||
        name.length > 512 ||
        cid is! String ||
        !_contentId.hasMatch(cid) ||
        size is! int ||
        size < 0 ||
        size > _maxCloudBytes ||
        created is! int ||
        created < 1 ||
        event.tsMs < 1 ||
        (mime != null && (mime is! String || mime.length > 255))) {
      return null;
    }
    return CloudItem(
      id: event.key,
      kind: kind,
      name: name,
      contentId: cid,
      size: size,
      mime: mime as String?,
      createdAtMs: created,
      modifiedAtMs: event.tsMs,
      revision: revision,
      deleted: false,
    );
  }

  static bool _validId(String id) =>
      id.isNotEmpty && id.length <= 128 && _itemId.hasMatch(id);

  static final _itemId = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _contentId = RegExp(r'^[0-9a-f]{64}$');
  static const _maxCloudBytes = 1 << 50; // current content tier: ~1 TiB
}

/// A device-authored proof-of-possession claim for one immutable cid. It is a
/// statement of local verified state, not a remote read oracle: claims travel
/// only inside the sovereign device group.
class CloudReplicaClaim {
  const CloudReplicaClaim({
    required this.itemId,
    required this.deviceId,
    required this.contentId,
    required this.present,
    required this.verifiedAtMs,
    required this.size,
  });

  final String itemId;
  final NodeId deviceId;
  final String contentId;
  final bool present;
  final int verifiedAtMs;
  final int size;

  String get key => '$itemId|${deviceId.hex}';

  DeviceSyncEvent toEvent() => DeviceSyncEvent(
    kind: DeviceSyncKind.cloudReplica,
    key: key,
    tsMs: verifiedAtMs,
    payload: {
      'device': deviceId.hex,
      'cid': contentId,
      'present': present,
      'size': size,
    },
  );

  static CloudReplicaClaim? fromEvent(DeviceSyncEvent event, {NodeId? author}) {
    if (event.kind != DeviceSyncKind.cloudReplica) return null;
    final separator = event.key.lastIndexOf('|');
    if (separator <= 0) return null;
    final itemId = event.key.substring(0, separator);
    final deviceHex = event.key.substring(separator + 1);
    if (!CloudItem._validId(itemId) || deviceHex.length != 64) return null;
    final p = event.payload;
    if (p['device'] != deviceHex ||
        p['cid'] is! String ||
        !CloudItem._contentId.hasMatch(p['cid'] as String) ||
        p['present'] is! bool ||
        p['size'] is! int ||
        (p['size'] as int) < 0 ||
        (p['size'] as int) > CloudItem._maxCloudBytes ||
        event.tsMs < 1) {
      return null;
    }
    final device = NodeId.fromHex(deviceHex);
    if (author != null && author != device) return null;
    return CloudReplicaClaim(
      itemId: itemId,
      deviceId: device,
      contentId: p['cid'] as String,
      present: p['present'] as bool,
      verifiedAtMs: event.tsMs,
      size: p['size'] as int,
    );
  }
}

enum CloudReplicationMode { all, selected, indexOnly }

class CloudReplicationProfile {
  const CloudReplicationProfile({
    this.mode = CloudReplicationMode.indexOnly,
    this.selectedItemIds = const {},
  });

  final CloudReplicationMode mode;
  final Set<String> selectedItemIds;

  bool wants(CloudItem item) => switch (mode) {
    CloudReplicationMode.all => !item.deleted,
    CloudReplicationMode.selected =>
      !item.deleted && selectedItemIds.contains(item.id),
    CloudReplicationMode.indexOnly => false,
  };

  String encode() => jsonEncode({
    'v': 1,
    'mode': mode.name,
    'selected': selectedItemIds.toList()..sort(),
  });

  static CloudReplicationProfile decode(String? raw) {
    if (raw == null || raw.isEmpty) return const CloudReplicationProfile();
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return const CloudReplicationProfile();
      }
      CloudReplicationMode? mode;
      for (final candidate in CloudReplicationMode.values) {
        if (candidate.name == value['mode']) mode = candidate;
      }
      if (mode == null) return const CloudReplicationProfile();
      final selected = value['selected'];
      return CloudReplicationProfile(
        mode: mode,
        selectedItemIds: {
          if (selected is List)
            for (final id in selected)
              if (id is String && CloudItem._validId(id)) id,
        },
      );
    } catch (_) {
      return const CloudReplicationProfile();
    }
  }
}

Map<String, CloudItem> foldCloudItems(Iterable<DeviceSyncEvent> events) {
  final folded = foldDeviceSync(events);
  final items = <String, CloudItem>{};
  for (final row in folded.entries) {
    if (row.key.$1 != DeviceSyncKind.cloudEntry) continue;
    final item = CloudItem.fromEvent(row.value);
    if (item != null) items[item.id] = item;
  }
  return items;
}

Map<String, CloudReplicaClaim> foldCloudReplicaClaims(
  Iterable<({DeviceSyncEvent event, NodeId author})> records,
) {
  final latest = <String, ({DeviceSyncEvent event, NodeId author})>{};
  for (final record in records) {
    final claim = CloudReplicaClaim.fromEvent(
      record.event,
      author: record.author,
    );
    if (claim == null) continue;
    final previous = latest[claim.key];
    if (previous == null || isNewerDeviceSync(record.event, previous.event)) {
      latest[claim.key] = record;
    }
  }
  final claims = <String, CloudReplicaClaim>{};
  for (final record in latest.values) {
    final claim = CloudReplicaClaim.fromEvent(
      record.event,
      author: record.author,
    );
    if (claim != null) claims[claim.key] = claim;
  }
  return claims;
}
