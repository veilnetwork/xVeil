import 'dart:convert';

import '../core/ids.dart';
import 'device_sync.dart';

enum CloudItemKind { file, note, task, calendarEvent }

/// One logical object in the personal-cloud index. The object id survives a
/// content update; [contentId] addresses the current immutable bytes. Deletes
/// are ABSORBING tombstones against anything at a lower revision: a stale row
/// (including a metadata-only folder move, which never bumps revision) can
/// never resurrect a deleted item on wall-clock alone. Only a row carrying a
/// genuinely new version (revision >= the tombstone's) competes by LWW, which
/// preserves the long-standing delete-vs-concurrent-edit semantics.
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
    this.folderId,
    this.thumbContentId,
    this.parentContentIds = const [],
  }) : assert(parentContentIds.length <= maxNoteParents);

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

  /// The [CloudFolder.id] this item lives in; null means the root. A dangling
  /// id (folder tombstoned by another device) renders as root — resolution is
  /// a view concern so a folder delete never rewrites item rows and can never
  /// race a concurrent content edit.
  final String? folderId;

  /// Content id of a small preview generated when the file was imported.
  ///
  /// A separate content object rather than bytes inline: the row replicates to
  /// every device of the identity and to everyone a folder is shared with, and
  /// a picture per row would bloat something that is read far more often than
  /// any single preview is looked at. Null for anything with no preview —
  /// notes, non-images, and everything imported before this existed.
  final String? thumbContentId;

  /// Immediate DAG parents for a whole-note revision. Empty on files, legacy
  /// rows, and a note's root revision. Multiple parents mean the author
  /// explicitly merged every listed offline head.
  final List<String> parentContentIds;

  static const maxNoteParents = 32;

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
            if (folderId != null) 'folder': folderId,
            if (thumbContentId != null) 'thumb': thumbContentId,
            if (parentContentIds.isNotEmpty) 'parents': parentContentIds,
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

  /// The same logical version relocated to [folderId] (null = root). A move is
  /// a metadata-only LWW rewrite: revision and content are untouched so an
  /// open editor keeps its optimistic check and the note DAG is unaffected.
  CloudItem movedToFolder(String? folderId, int atMs) => CloudItem(
    id: id,
    kind: kind,
    name: name,
    contentId: contentId,
    size: size,
    mime: mime,
    createdAtMs: createdAtMs,
    modifiedAtMs: atMs,
    revision: revision,
    deleted: deleted,
    folderId: folderId,
    thumbContentId: thumbContentId,
    parentContentIds: parentContentIds,
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
    // Folder assignment is decoration, not content. A value this vocabulary
    // cannot parse (e.g. a future nested-path format) degrades to the root
    // instead of hiding the whole document row.
    final rawFolder = p['folder'];
    final folder = rawFolder is String && _validId(rawFolder)
        ? rawFolder
        : null;
    // Same forgiving treatment as the folder: a preview is decoration, so an
    // unparsable value costs the preview, never the row.
    final rawThumb = p['thumb'];
    final thumb = rawThumb is String && _contentId.hasMatch(rawThumb)
        ? rawThumb
        : null;
    final rawParents = p['parents'];
    final parents = <String>[];
    if (rawParents != null) {
      if (rawParents is! List || rawParents.length > maxNoteParents) {
        return null;
      }
      for (final parent in rawParents) {
        if (parent is! String ||
            !_contentId.hasMatch(parent) ||
            parents.contains(parent)) {
          return null;
        }
        parents.add(parent);
      }
    }
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
    if (parents.isNotEmpty &&
        (kind != CloudItemKind.note || parents.contains(cid))) {
      return null;
    }
    for (var index = 1; index < parents.length; index++) {
      if (parents[index - 1].compareTo(parents[index]) >= 0) return null;
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
      folderId: folder,
      thumbContentId: thumb,
      parentContentIds: List.unmodifiable(parents),
    );
  }

  static bool _validId(String id) =>
      id.isNotEmpty && id.length <= 128 && _itemId.hasMatch(id);

  static final _itemId = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _contentId = RegExp(r'^[0-9a-f]{64}$');
  static const _maxCloudBytes = 1 << 50; // current content tier: ~1 TiB
}

/// One flat personal-cloud folder. Folders are pure owner-side organization of
/// the signed device-group index: no content refs, no sharing surface, no new
/// crypto. Deletes are plain LWW tombstones (every folder mutation bumps
/// revision, so the same-revision resurrection [CloudItem]'s absorbing
/// tombstone guards against cannot arise here); contained items are NOT
/// rewritten on delete — their dangling [CloudItem.folderId] resolves to the
/// root at view time, so no document is ever lost.
class CloudFolder {
  const CloudFolder({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.modifiedAtMs,
    required this.revision,
    required this.deleted,
    this.parentId,
  });

  final String id;
  final String name;
  final int createdAtMs;
  final int modifiedAtMs;
  final int revision;
  final bool deleted;

  /// Parent folder id; null = a root-level folder. Like [CloudItem.folderId]
  /// this is decoration resolved at view time: a dangling/dead parent makes
  /// the folder (and its contents) surface under the nearest LIVE ancestor,
  /// and a cross-device merge that forms a parent cycle is broken
  /// deterministically by the resolver — rows are never rewritten for
  /// either, so structure changes can never LWW-clobber concurrent edits.
  final String? parentId;

  DeviceSyncEvent toEvent() => DeviceSyncEvent(
    kind: DeviceSyncKind.cloudFolder,
    key: id,
    tsMs: modifiedAtMs,
    payload: deleted
        // A tombstone keeps its parent pointer: the resolver walks DEAD
        // folders through, lifting orphaned contents to the nearest LIVE
        // ancestor instead of dumping them at the root.
        ? {
            'del': true,
            'rev': revision,
            if (parentId != null) 'parent': parentId,
          }
        : {
            'name': name,
            'created': createdAtMs,
            'rev': revision,
            if (parentId != null) 'parent': parentId,
          },
  );

  CloudFolder tombstone(int atMs) => CloudFolder(
    id: id,
    name: '',
    createdAtMs: createdAtMs,
    modifiedAtMs: atMs,
    revision: revision + 1,
    deleted: true,
    parentId: parentId,
  );

  static CloudFolder? fromEvent(DeviceSyncEvent event) {
    if (event.kind != DeviceSyncKind.cloudFolder ||
        !CloudItem._validId(event.key) ||
        event.tsMs < 1) {
      return null;
    }
    final p = event.payload;
    final revision = p['rev'];
    if (revision is! int || revision < 1) return null;
    final rawParent = p['parent'];
    final parent =
        rawParent is String &&
            CloudItem._validId(rawParent) &&
            rawParent != event.key
        ? rawParent
        : null;
    if (p['del'] == true) {
      return CloudFolder(
        id: event.key,
        name: '',
        createdAtMs: event.tsMs,
        modifiedAtMs: event.tsMs,
        revision: revision,
        deleted: true,
        parentId: parent,
      );
    }
    final name = p['name'];
    final created = p['created'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 512 ||
        created is! int ||
        created < 1) {
      return null;
    }
    // Parent is decoration like CloudItem.folderId: an unparseable value (a
    // future vocabulary, or a self-reference) degrades to a root folder
    // instead of hiding the whole row.
    return CloudFolder(
      id: event.key,
      name: name,
      createdAtMs: created,
      modifiedAtMs: event.tsMs,
      revision: revision,
      deleted: false,
      parentId: parent,
    );
  }
}

Map<String, CloudFolder> foldCloudFolders(Iterable<DeviceSyncEvent> events) {
  final folded = foldDeviceSync(events);
  final folders = <String, CloudFolder>{};
  for (final row in folded.entries) {
    if (row.key.$1 != DeviceSyncKind.cloudFolder) continue;
    final folder = CloudFolder.fromEvent(row.value);
    if (folder != null) folders[folder.id] = folder;
  }
  return folders;
}

/// A device-authored proof-of-possession claim for one immutable cid. It is a
/// statement of local verified state, not a remote read oracle: claims travel
/// only inside the sovereign device group.
/// What one device of the identity is holding.
class CloudDeviceUsage {
  const CloudDeviceUsage({
    required this.deviceId,
    required this.isSelf,
    required this.items,
    required this.bytes,
  });

  final NodeId deviceId;
  final bool isSelf;
  final int items;
  final int bytes;
}

/// What the cloud costs — here, and across the identity's devices.
///
/// Every number is folded from state that already replicates: a replica claim
/// carries the size of what it claims, so "which of my devices is holding what"
/// is answerable without asking any of them. Nothing here goes on the wire.
///
/// There is deliberately no quota. Nobody issues one in this network and nobody
/// could enforce it; what a caller can honestly show is what is being used.
class CloudUsage {
  const CloudUsage({
    required this.logicalItems,
    required this.logicalBytes,
    required this.localItems,
    required this.localBytes,
    required this.indexOnlyItems,
    required this.devices,
  });

  /// Everything the index knows about, wherever it physically lives.
  final int logicalItems;
  final int logicalBytes;

  /// The part of it whose bytes are on THIS device — what it costs the disk.
  final int localItems;
  final int localBytes;

  /// Known here, held elsewhere. The gap between the two pairs above, and the
  /// thing that makes the `all` replication mode's cost predictable.
  final int indexOnlyItems;

  /// Per device, self included, largest holder first.
  final List<CloudDeviceUsage> devices;
}

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

  /// v2 convergence key includes cid so one device can truthfully advertise
  /// several unresolved note heads. The parser still accepts legacy
  /// `item|device` events written before branch preservation.
  String get key => '$itemId|${deviceId.hex}|$contentId';

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
    final parts = event.key.split('|');
    if (parts.length != 2 && parts.length != 3) return null;
    final itemId = parts[0];
    final deviceHex = parts[1];
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
    if (parts.length == 3 && parts[2] != p['cid']) return null;
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
  final source = events.toList();
  // Absorbing guard, pass 1: the highest tombstone revision per id across the
  // WHOLE log — a tombstone must absorb stale rows even when it loses the
  // plain newest-timestamp race (e.g. to a concurrent metadata-only folder
  // move, which never bumps revision).
  final tombstoneRevision = <String, int>{};
  for (final event in source) {
    final item = CloudItem.fromEvent(event);
    if (item == null || !item.deleted) continue;
    final previous = tombstoneRevision[item.id];
    if (previous == null || item.revision > previous) {
      tombstoneRevision[item.id] = item.revision;
    }
  }
  // Pass 2: newest-wins over the surviving candidates. A live row below the
  // tombstone's revision is a version the deletion already covered; only a
  // genuinely newer version (concurrent edit, revision >= tombstone) may
  // still recreate the item by LWW — the pre-folder semantics.
  final winners = <String, ({CloudItem item, DeviceSyncEvent event})>{};
  for (final event in source) {
    final item = CloudItem.fromEvent(event);
    if (item == null) continue;
    final tombstone = tombstoneRevision[item.id];
    if (!item.deleted && tombstone != null && item.revision < tombstone) {
      continue;
    }
    final previous = winners[item.id];
    if (previous == null || isNewerDeviceSync(event, previous.event)) {
      winners[item.id] = (item: item, event: event);
    }
  }
  return {for (final entry in winners.entries) entry.key: entry.value.item};
}

/// Fold every parent-aware whole-note revision into its unresolved DAG heads.
/// A cid is superseded only by a strictly higher revision that names it as an
/// immediate parent. Two devices editing the same parent therefore yield two
/// durable heads instead of whichever LWW timestamp happened to win.
///
/// Legacy note rows carried no parents. Until the first parent-aware revision
/// exists for an item they retain the old single-winner behavior, avoiding a
/// false conflict explosion during migration.
Map<String, List<CloudItem>> foldCloudNoteHeads(
  Iterable<DeviceSyncEvent> events,
) {
  final source = events.toList();
  final winners = foldCloudItems(source);
  final byItem =
      <String, Map<String, ({CloudItem item, DeviceSyncEvent event})>>{};
  for (final event in source) {
    final item = CloudItem.fromEvent(event);
    if (item == null || item.deleted || item.kind != CloudItemKind.note) {
      continue;
    }
    final cid = item.contentId!;
    final versions = byItem.putIfAbsent(item.id, () => {});
    final previous = versions[cid];
    if (previous == null || isNewerDeviceSync(event, previous.event)) {
      versions[cid] = (item: item, event: event);
    }
  }

  final result = <String, List<CloudItem>>{};
  for (final entry in byItem.entries) {
    final winner = winners[entry.key];
    if (winner == null || winner.deleted || winner.kind != CloudItemKind.note) {
      continue;
    }
    final versions = entry.value;
    if (!versions.values.any(
      (version) => version.item.parentContentIds.isNotEmpty,
    )) {
      result[entry.key] = [winner];
      continue;
    }
    final superseded = <String>{};
    for (final child in versions.values.map((version) => version.item)) {
      for (final parentCid in child.parentContentIds) {
        final parent = versions[parentCid]?.item;
        if (parent != null && parent.revision < child.revision) {
          superseded.add(parentCid);
        }
      }
    }
    final heads =
        [
          for (final version in versions.values)
            if (!superseded.contains(version.item.contentId)) version.item,
        ]..sort((a, b) {
          final revision = b.revision.compareTo(a.revision);
          if (revision != 0) return revision;
          final modified = b.modifiedAtMs.compareTo(a.modifiedAtMs);
          if (modified != 0) return modified;
          return a.contentId!.compareTo(b.contentId!);
        });
    if (heads.isNotEmpty) {
      result[entry.key] = List.unmodifiable(heads);
    }
  }
  return result;
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
