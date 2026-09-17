// Walking everything this identity holds into an archive.
//
// The shape of the walk is not new: it emits the SAME events the multi-device
// sync emits when two devices are online together — contact upserts, message
// mirrors, read marks, call-journal rows, settings. Offline transfer is
// therefore the same merge as online sync, carried by a file instead of by the
// device group, and the rules for what beats what live in exactly one place
// (`foldDeviceSync` and `DeviceSyncApplyGate`). A second vocabulary here would
// mean two answers to "which of these two devices is right".
//
// What travels OUTSIDE that vocabulary, and why:
//
//  * the node identity — it is not mergeable, it is the thing being moved.
//    Included only when the person asked for it; an archive with it in is the
//    identity, and the interface says so before it is written.
//  * the owner's profile — one record, last-writer-wins is meaningless for it
//    offline because there is no clock either side trusts.
//  * settings that the device-group sync does NOT carry. Its allowlist is
//    deliberately narrow (three keys), because a preference like a window size
//    or a file path is local to a machine. But the container also holds
//    identity-level settings under the same namespace — a claimed nickname,
//    for instance — and dropping those would silently lose them. They travel
//    as their own record kind, and the importer FILLS A GAP with them rather
//    than overwriting: an archive must not decide that this device's nickname
//    was the wrong one.
//  * stored files, as their bytes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../data/node/sovereign_identity_material.dart'
    show readSovereignCredential;
import '../data/storage/storage.dart';
import '../domain/chat.dart';
import '../domain/data_transfer.dart';
import '../domain/device_sync.dart';
import 'transferable_settings.dart';
import 'device_sync_bridge.dart' show contactPrefsPayload;

/// Files larger than this are named in the archive but their bytes are not
/// carried.
///
/// The archive streams, so size alone is not the problem; the IMPORT side is,
/// because putting a file back means handing the store one buffer. Rather than
/// half-support a piece protocol in the first version, the limit is stated,
/// reported per file, and the person is told which files stayed behind.
const int kExportFileByteCeiling = 64 * 1024 * 1024;

/// What an export would contain — answered before it runs, so the person can
/// be asked about the files with the two sizes in front of them.
class DataExportPlan {
  const DataExportPlan({
    required this.contacts,
    required this.messages,
    required this.settings,
    required this.callLogEntries,
    required this.files,
    required this.fileBytes,
    required this.oversizeFiles,
  });

  final int contacts;
  final int messages;
  final int settings;
  final int callLogEntries;

  /// Files whose bytes CAN be carried.
  final int files;
  final int fileBytes;

  /// Files past [kExportFileByteCeiling] — counted so the person is told, not
  /// discovered afterwards.
  final int oversizeFiles;

  /// A rough size for the archive WITHOUT files.
  ///
  /// Rough on purpose and named so: it is a count-based estimate, and the real
  /// figure depends on how long the messages are. It exists to answer "is this
  /// megabytes or gigabytes", which is the question the file prompt is really
  /// asking.
  int get estimatedBytesWithoutFiles =>
      (contacts * 320) +
      (messages * 512) +
      (settings * 256) +
      (callLogEntries * 192) +
      4096;

  int get estimatedBytesWithFiles => estimatedBytesWithoutFiles + fileBytes;
}

/// What an export actually did.
class DataExportReport {
  const DataExportReport({
    required this.records,
    required this.files,
    required this.skippedFiles,
    required this.bytes,
    this.groups = 0,
    this.skippedGroups = const [],
  });

  final int records;
  final int files;

  /// Files whose bytes were left out, by id, so the report can name them.
  final List<String> skippedFiles;
  final int bytes;

  /// Groups and Spaces carried, as whole snapshots.
  final int groups;

  /// Groups that did NOT fit, by id. A snapshot past
  /// [kTransferMaxRecordBytes] is a record no importer would accept, so it is
  /// left out and named rather than written and refused on the other side.
  final List<String> skippedGroups;
}

/// Reads an open space and writes it as an archive.
class DataExporter {
  DataExporter({
    required Storage storage,
    required String nodeIdHex,
    required Set<String> syncedSettingKeys,
    ArchiveGroups? groups,
    int Function()? nowMs,
    int fileCeiling = kExportFileByteCeiling,
  }) : this._(
         storage,
         nodeIdHex,
         syncedSettingKeys,
         groups,
         nowMs ?? _wallClock,
         fileCeiling,
       );

  // Positional, because a named parameter cannot carry a private field's name
  // and the analyzer asks for initializing formals either way.
  DataExporter._(
    this._storage,
    this._nodeIdHex,
    this._syncedSettingKeys,
    this._groups,
    this._now,
    this._fileCeiling,
  );

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final Storage _storage;

  /// The group layer, or `null` where there is none to ask.
  ///
  /// Nullable rather than required because an export can run in places that
  /// have no group service — the headless paths and the transfer tests. What it
  /// must NOT do is pretend: an export without this carries no groups, and the
  /// report says `groups: 0` rather than leaving the person to assume.
  final ArchiveGroups? _groups;

  final String _nodeIdHex;

  /// The settings the device-group sync carries, asked of the hub rather than
  /// copied from it — see [DeviceSettingsSyncHub.syncedKeys].
  final Set<String> _syncedSettingKeys;
  final int Function() _now;
  final int _fileCeiling;

  /// Count what is there, without reading a byte of file content.
  Future<DataExportPlan> plan() async {
    final conversations = await _storage.loadConversations();
    var messages = 0;
    for (final c in conversations) {
      messages += (await _storage.loadMessages(c.id)).length;
    }
    // Only what will actually travel. Counting every key in the namespace made
    // the preview promise settings the export then dropped in silence — and a
    // count is exactly what a person checks the archive against afterwards
    // (report24 CH-W1).
    final settings = (await _storage.settingsKeys())
        .where((k) => _syncedSettingKeys.contains(k) || isTransferableSetting(k))
        .toList();
    final calls = await _storage.callLogEntries();

    var files = 0;
    var oversize = 0;
    var fileBytes = 0;
    final snapshot = await _storage.sharedContentReferenceSnapshot();
    for (final id in snapshot.storedContentIds) {
      final size = await _storage.fileSize(id) ?? 0;
      if (size > _fileCeiling) {
        oversize++;
        continue;
      }
      files++;
      fileBytes += size;
    }

    return DataExportPlan(
      contacts: conversations.length,
      messages: messages,
      settings: settings.length,
      callLogEntries: calls.length,
      files: files,
      fileBytes: fileBytes,
      oversizeFiles: oversize,
    );
  }

  /// Write the archive through [sink].
  ///
  /// [password] seals it; null writes it open. [includeIdentity] decides
  /// whether the archive can make a fresh install into this device — the
  /// caller is the one that must have said so out loud.
  Future<DataExportReport> run({
    required Future<void> Function(List<int> bytes) sink,
    String? password,
    bool includeIdentity = false,
    bool includeFiles = true,
    String? label,
    void Function(int done, int total)? onProgress,
    TransferSeal? cost,
  }) async {
    final counted = await plan();
    var written = 0;
    var total = counted.contacts * 2 + counted.messages + counted.settings +
        counted.callLogEntries + (includeFiles ? counted.files : 0) + 2;
    if (total <= 0) total = 1;
    var bytes = 0;

    final writer = await DataTransferWriter.open(
      sink: (b) async {
        bytes += b.length;
        await sink(b);
      },
      header: TransferHeader(
        createdMs: _now(),
        nodeIdHex: _nodeIdHex,
        label: label,
        includesIdentity: includeIdentity,
        includesFiles: includeFiles,
        counts: {
          'contacts': counted.contacts,
          'messages': counted.messages,
          'settings': counted.settings,
          'calls': counted.callLogEntries,
          'files': includeFiles ? counted.files : 0,
        },
        fileBytes: includeFiles ? counted.fileBytes : 0,
      ),
      password: password,
      cost: cost,
    );

    var records = 0;
    void step() {
      written++;
      onProgress?.call(written, total);
    }

    // THE ARCHIVE'S EVENTS ARE OLDER THAN ANYTHING A LIVE DEVICE KNOWS.
    //
    // They used to be stamped `now` — the moment of EXPORT — so importing an
    // archive taken from a device that had been offline for a month made every
    // stale value the newest one the fold had ever seen: an `accepted` contact
    // could be put back to `blocked`, a setting could be rolled back, and
    // nothing said so (report27 X05). Nothing in the container records when a
    // contact's status was actually decided, so there is no honest "when" to
    // carry.
    //
    // A counter instead: relative order INSIDE the archive is preserved, and
    // against any real event (milliseconds since 1970) every one of these
    // loses. That makes an archive what it can honestly be — a way to fill
    // what a device does not have, never a way to overwrite what it does.
    // Restoring onto a fresh device is unaffected: there is nothing to lose to.
    var archiveOrder = 0;
    int nextArchiveStamp() => ++archiveOrder;

    Future<void> emit(DeviceSyncEvent e) async {
      await writer.add(
        TransferRecord(
          kind: TransferRecordKind.sync,
          meta: {'b': e.toBody()},
        ),
      );
      records++;
    }

    // 1. Who this is.
    final profile = await _storage.loadProfile();
    if (profile != null) {
      await writer.add(
        TransferRecord(
          kind: TransferRecordKind.profile,
          meta: {
            'displayName': profile.displayName,
            'username': profile.username,
          },
        ),
      );
      records++;
    }
    step();

    // 2. The identity itself, if asked for.
    if (includeIdentity) {
      final toml = await _storage.loadNodeConfig();
      if (toml != null) {
        final payload = Uint8List.fromList(utf8.encode(toml));
        await writer.add(
          TransferRecord(kind: TransferRecordKind.identity, payload: payload),
        );
        records++;
      }
      // AND THE CREDENTIAL, which is the part that is actually the identity.
      //
      // The node config above is the transport key. The address a person's
      // contacts hold comes from the hybrid master in here, and its Falcon
      // half is reproducible from nothing at all — not from the phrase, not
      // from the config, not from the network. An archive without it restores
      // a device that talks on the right wire key and answers where nobody
      // writes; reported as "восстановилась другая личность (другой node_id)".
      //
      // It travels ENCRYPTED, byte for byte as the container holds it. The
      // archive carries a locked box: an XVSB still needs the 24 words and an
      // XVRC still needs its code, so an archive alone is not the identity
      // even when it is not sealed.
      final credential = await readSovereignCredential(_storage);
      final bundle = credential.bundle;
      if (bundle != null && bundle.isNotEmpty) {
        await writer.add(
          TransferRecord(
            kind: TransferRecordKind.credential,
            payload: Uint8List.fromList(bundle),
          ),
        );
        records++;
      }
    }
    step();

    // 3. Settings. The three the device group syncs travel as sync events, so
    //    they merge by the same rule online sync uses; the rest travel raw.
    for (final key in await _storage.settingsKeys()) {
      final value = await _storage.getSetting(key);
      if (value == null) continue;
      if (_syncedSettingKeys.contains(key)) {
        await emit(
          DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: key,
            tsMs: nextArchiveStamp(),
            payload: {'v': value},
          ),
        );
      } else if (isTransferableSetting(key)) {
        await writer.add(
          TransferRecord(
            kind: TransferRecordKind.setting,
            meta: {'key': key, 'v': value},
          ),
        );
        records++;
      }
      // Everything else stays: the settings namespace also holds credentials
      // and machine-local state, and an archive is not how either of those
      // moves. See transferable_settings.dart for what travels and why.
      step();
    }

    // 4. Conversations: the contact, where it was read to, and the messages.
    for (final conversation in await _storage.loadConversations()) {
      final contact = conversation.peer;
      final peerHex = contact.nodeId.hex;
      {
        await emit(
          DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: peerHex,
            tsMs: nextArchiveStamp(),
            payload: contactPrefsPayload(contact),
          ),
        );
        // Status rides its own key namespace, exactly as it does live, so an
        // alias edit and a block cannot overwrite one another.
        await emit(
          DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: 's:$peerHex',
            tsMs: nextArchiveStamp(),
            payload: {'status': contact.status.name},
          ),
        );
      }
      step();

      final readAt = await _storage.readMarker(conversation.id);
      if (readAt > 0) {
        await emit(
          DeviceSyncEvent(
            kind: DeviceSyncKind.readMark,
            key: conversation.id,
            // The watermark IS the timestamp, as in the live emit: two devices
            // that read independently converge on the later one.
            tsMs: readAt,
            payload: const {},
          ),
        );
      }
      step();

      for (final message in await _storage.loadMessages(conversation.id)) {
        await emit(_mirrorOf(peerHex, message));
        step();
      }
    }

    // 5. The call journal.
    for (final entry in await _storage.callLogEntries()) {
      await emit(
        DeviceSyncEvent(
          kind: DeviceSyncKind.callLog,
          key: entry.id,
          tsMs: entry.atMs,
          payload: entry.toJson(),
        ),
      );
      step();
    }

    // 6. Groups and Spaces, one snapshot each: the manifest, the signed
    //    control log, the epoch keys and the history.
    //
    //    Whole snapshots rather than rows, because that is the unit the group
    //    layer already knows how to write and to read — the same one a device
    //    seed sends a sibling. Rows would mean a second merge, written here,
    //    disagreeing with the one on the wire.
    var groupsCarried = 0;
    final skippedGroups = <String>[];
    final groups = _groups;
    if (groups != null) {
      for (final gid in await groups.archivableGroupIds()) {
        final snapshot = await groups.archiveSnapshot(gid);
        if (snapshot == null) continue;
        final payload = Uint8List.fromList(utf8.encode(snapshot));
        if (payload.length > kTransferMaxRecordBytes) {
          // Named, not silently dropped: the same discipline as an oversize
          // file. A record this long is one the importer refuses outright, so
          // writing it would lose the whole archive rather than one group.
          skippedGroups.add(gid);
          continue;
        }
        await writer.add(
          TransferRecord(
            kind: TransferRecordKind.group,
            meta: {'gid': gid},
            payload: payload,
          ),
        );
        records++;
        groupsCarried++;
        step();
      }
    }

    // 7. The files, streamed — a phone must be able to export a gigabyte
    //    without holding a gigabyte.
    final skipped = <String>[];
    var files = 0;
    if (includeFiles) {
      final snapshot = await _storage.sharedContentReferenceSnapshot();
      for (final id in snapshot.storedContentIds) {
        final size = await _storage.fileSize(id) ?? 0;
        if (size > _fileCeiling) {
          skipped.add(id);
          continue;
        }
        await writer.addStreamed(
          kind: TransferRecordKind.file,
          meta: {'id': id},
          length: size,
          payload: _fileChunks(id, size),
        );
        records++;
        files++;
        step();
      }
    }

    await writer.close();
    return DataExportReport(
      records: records,
      files: files,
      skippedFiles: skipped,
      bytes: bytes,
      groups: groupsCarried,
      skippedGroups: skippedGroups,
    );
  }

  /// The message mirror the live path emits, from a stored message.
  ///
  /// Deliberately the same field names: an importer reading this cannot tell
  /// whether the event arrived over the device group or out of a file, and
  /// that is the property that keeps one merge rule instead of two.
  DeviceSyncEvent _mirrorOf(String peerHex, Message message) {
    final contentId = message.fileContentId ?? message.fileId;
    return DeviceSyncEvent(
      kind: DeviceSyncKind.msgMirror,
      key: message.id,
      tsMs: message.timestamp.millisecondsSinceEpoch,
      payload: {
        'peer': peerHex,
        'dir': message.direction.name,
        'body': message.body,
        // The bytes stay where they are: a mirror carries the CONTENT ID, and
        // the file record (or the peer) supplies the bytes. Same as the live
        // emit, which is the point.
        if (contentId != null) ...{
          'cid': contentId,
          'fname': message.fileName,
          'fsize': message.fileSize,
        },
      },
    );
  }

  Stream<List<int>> _fileChunks(String id, int size) async* {
    const window = 1 << 20;
    var offset = 0;
    while (offset < size) {
      final want = (size - offset) < window ? (size - offset) : window;
      final chunk = await _storage.readFileRange(id, offset, want);
      if (chunk == null || chunk.isEmpty) {
        throw StateError('file $id ended at $offset of $size');
      }
      offset += chunk.length;
      yield chunk;
    }
  }
}
