// Export a device, import it into another, and check what actually arrives.
//
// The case this exists for is the one that was asked for: two devices of ONE
// identity that lived apart, merged offline. So the assertions are about the
// merge, not about the file — the file has its own test next door:
//
//  * everything the first device holds leaves as an event the SECOND device's
//    appliers already understand (the same events a sibling device would have
//    sent, which is what keeps one merge rule instead of two);
//  * importing the same archive twice adds nothing the second time — proved by
//    folding the delivered events the way the live path folds them;
//  * an archive from a DIFFERENT identity is refused before a byte is applied;
//  * an archive carrying an identity is refused by a device that has one.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart'
    show kSovereignBundleSetting;
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/data_transfer.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/data_export.dart';
import 'package:xveil/state/data_import.dart';
import 'package:xveil/state/device_sync_appliers.dart';

/// An in-memory space: only what an export reads and an import writes.
///
/// Anything else reached through this hits `noSuchMethod` and fails loudly,
/// the same posture as the other fakes in this suite — a default that quietly
/// satisfies a test is worse than a missing method.
class _Space implements Storage {
  _Space({this.nodeConfig});

  UserProfile? profile;
  String? nodeConfig;
  final Map<String, String> settings = {};
  final List<Conversation> conversations = [];
  final Map<String, List<Message>> messages = {};
  final Map<String, int> readMarks = {};
  final List<CallLogEntry> calls = [];
  final Map<String, Uint8List> files = {};

  @override
  Future<UserProfile?> loadProfile() async => profile;

  @override
  Future<void> saveProfile(UserProfile p) async => profile = p;

  @override
  Future<String?> loadNodeConfig() async => nodeConfig;

  @override
  Future<void> saveNodeConfig(String toml) async => nodeConfig = toml;

  @override
  Future<List<String>> settingsKeys() async => settings.keys.toList();

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;

  @override
  Future<List<Conversation>> loadConversations() async => conversations;

  @override
  Future<List<Message>> loadMessages(String conversationId, {int? limit}) async =>
      messages[conversationId] ?? const [];

  @override
  Future<int> readMarker(String conversationId) async =>
      readMarks[conversationId] ?? 0;

  @override
  Future<List<CallLogEntry>> callLogEntries() async => calls;

  @override
  Future<SharedContentReferenceSnapshot>
  sharedContentReferenceSnapshot() async => SharedContentReferenceSnapshot(
    storedContentIds: files.keys.toSet(),
    referencedContentIds: files.keys.toSet(),
    complete: true,
  );

  @override
  Future<int?> fileSize(String fileId) async => files[fileId]?.length;

  @override
  Future<Uint8List?> readFileRange(String id, int offset, int length) async {
    final bytes = files[id];
    if (bytes == null) return null;
    final end = offset + length;
    return Uint8List.sublistView(
      bytes,
      offset,
      end > bytes.length ? bytes.length : end,
    );
  }

  @override
  Future<bool> hasFile(String fileId) async => files.containsKey(fileId);

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async =>
      files[fileId] = bytes;

  // Present because the sovereign credential is read through it. Without the
  // override `noSuchMethod` throws, the credential reader catches that as "no
  // credential", and a test asserting the credential travels would have been
  // measuring the fixture.
  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Collects what the appliers would have been given.
///
/// Standing in for the real appliers on purpose: they live inside the running
/// app's providers, and what this test is about is WHICH events reach them.
class _Collector {
  final events = <DeviceSyncEvent>[];

  DeviceSyncAppliers get appliers {
    final a = DeviceSyncAppliers();
    a.register(events.add);
    return a;
  }
}

/// 64 hex characters that differ per [n] — a node id shaped like a real one.
String hexOf(int n) => (n.toRadixString(16) * 64).substring(0, 64);

_Space _deviceWithHistory() {
  final space = _Space(nodeConfig: '[identity]\nkey = "secret"\n');
  space.profile = const UserProfile(displayName: 'Ann', username: 'ann');
  space.settings['locale'] = 'ru';
  space.settings['nickname:claimed'] = '{"name":"ann","weight":9}';
  space.settings['window_width'] = '900';

  final peer = NodeId.fromHex(hexOf(3));
  space.conversations.add(
    Conversation(peer: Contact(nodeId: peer, name: 'Bob')),
  );
  space.messages[peer.hex] = [
    Message(
      id: 'm1',
      conversationId: peer.hex,
      direction: MessageDirection.outgoing,
      body: 'first',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      status: MessageStatus.sent,
    ),
    Message(
      id: 'm2',
      conversationId: peer.hex,
      direction: MessageDirection.incoming,
      body: 'second',
      timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
      status: MessageStatus.sent,
    ),
  ];
  space.readMarks[peer.hex] = 2000;
  space.calls.add(
    const CallLogEntry(
      id: 'c1',
      peerHex: 'ff',
      outgoing: true,
      video: false,
      outcome: CallLogOutcome.completed,
      atMs: 1500,
    ),
  );
  space.files['file-1'] = Uint8List.fromList(utf8.encode('an attachment'));
  return space;
}

TransferSeal cheapCost() => TransferSeal(
  salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
  memoryKib: 1024,
  iterations: 1,
  parallelism: 1,
  chunkBytes: 64 * 1024,
);

/// A stand-in group layer: it hands out snapshots by id and remembers what it
/// was asked to put back.
///
/// The real one is exercised where it lives (`group_service_test`, report27
/// X08): that a snapshot carries the epoch keys and that a restore rebuilds a
/// readable group is the group layer's business. What belongs HERE is the
/// plumbing — that a group leaves as a record, arrives as one, and is counted
/// honestly when it cannot be put back.
class _Groups implements ArchiveGroups {
  _Groups(this.snapshots);

  final Map<String, String> snapshots;
  final List<String> restored = [];

  /// Ids whose restore answers no, so the refusal count has something to count.
  final Set<String> refuse = {};

  @override
  Future<List<String>> archivableGroupIds() async => snapshots.keys.toList();

  @override
  Future<String?> archiveSnapshot(String groupIdHex) async =>
      snapshots[groupIdHex];

  @override
  Future<bool> restoreSnapshot(String snapshotJson) async {
    final id = (jsonDecode(snapshotJson) as Map)['id'] as String;
    if (refuse.contains(id)) return false;
    restored.add(id);
    return true;
  }
}

/// A stand-in cloud layer: it hands out rows and remembers what it took.
///
/// The real merge is exercised where it lives (`cloud_service_test`, report27
/// X08). What belongs here is that the rows leave, arrive, reach the layer that
/// claims them — and are counted rather than quietly passed off as merged when
/// no layer does.
class _Cloud implements ArchiveCloud {
  _Cloud(this.kinds, [this.rows = const []]);

  final Set<DeviceSyncKind> kinds;
  final List<DeviceSyncEvent> rows;
  final List<DeviceSyncEvent> adopted = [];

  @override
  bool claimsSyncKind(DeviceSyncKind kind) => kinds.contains(kind);

  @override
  Future<List<DeviceSyncEvent>> archivableCloudEvents() async => rows;

  @override
  Future<int> adoptArchivedCloudEvents(List<DeviceSyncEvent> events) async {
    adopted.addAll(events);
    return events.length;
  }
}

DeviceSyncEvent _cloudRow(DeviceSyncKind kind, String key) =>
    DeviceSyncEvent(kind: kind, key: key, tsMs: 7000, payload: const {});

Future<Uint8List> _exportOf(
  _Space space, {
  String? password,
  bool includeIdentity = false,
  bool includeFiles = true,
  ArchiveGroups? groups,
  List<ArchiveCloud> cloud = const [],
}) async {
  final out = BytesBuilder();
  await DataExporter(
    storage: space,
    nodeIdHex: hexOf(1),
    syncedSettingKeys: {'locale'},
    groups: groups,
    cloud: cloud,
    nowMs: () => 5000,
  ).run(
    sink: (b) async => out.add(b),
    password: password,
    includeIdentity: includeIdentity,
    includeFiles: includeFiles,
    cost: password == null ? null : cheapCost(),
  );
  return out.takeBytes();
}

void main() {
  /// An archive that stops part-way says what it already applied.
  ///
  /// A streaming import applies as it reads — that is what lets an archive
  /// larger than memory be merged at all — so a truncated file leaves real
  /// changes behind. They were reported as the same bare failure a file that
  /// was never readable gets, with nothing to say part of it had landed and
  /// nothing to say whether trying again was safe (report27 X10). It is: every
  /// record here is idempotent.
  test('a truncated archive reports what it managed to merge', () async {
    final archive = await _exportOf(_deviceWithHistory());
    // Cut it short well past the header, so records really do apply first.
    final cut = Uint8List.sublistView(archive, 0, (archive.length * 3) ~/ 4);

    final collector = _Collector();
    final target = _Space();
    Object? thrown;
    try {
      await DataImporter(
        storage: target,
        appliers: collector.appliers,
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(cut));
    } catch (e) {
      thrown = e;
    }

    expect(
      thrown,
      isA<ImportInterrupted>(),
      reason:
          'a truncated archive threw $thrown — the same shape a file that was '
          'never readable throws, with nothing about what had already landed',
    );
    final partial = (thrown! as ImportInterrupted).partial;
    expect(
      partial.syncEvents,
      greaterThan(0),
      reason:
          'the report says nothing was applied, and the appliers were handed '
          '${collector.events.length} events',
    );
    expect(
      partial.syncEvents,
      collector.events.length,
      reason: 'the count must be what actually reached the appliers',
    );
    expect(
      (thrown as ImportInterrupted).cause,
      isA<TransferException>(),
      reason: 'the reason it stopped has to travel with it',
    );
  });

  /// A write that threw is not a merge that finished.
  ///
  /// The apply gate survives a failed write on purpose — it must not poison
  /// the slot behind it — and the count stopped there. `settle` returned
  /// normally, the importer reported a merge, and the screen said so with part
  /// of the archive not on disk. The only counter beside it,
  /// `unconfirmedAppliers`, is about appliers that cannot report at all, which
  /// is a different fact (report27 X06).
  test('a merge whose writes failed says so', () async {
    final archive = await _exportOf(_deviceWithHistory());
    final gate = DeviceSyncApplyGate();
    final report = await DataImporter(
      storage: _Space(),
      appliers: DeviceSyncAppliers()
        ..register(
          (event, {attachmentThumb}) async {
            gate.offer(event, () => () async {
              throw StateError('the disk said no');
            });
          },
          settle: gate.settle,
          failures: () => gate.failedApplies,
        ),
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));

    expect(
      report.syncEvents,
      greaterThan(3),
      reason: 'premise: the archive has to carry events to fail on',
    );
    expect(
      report.failedApplies,
      report.syncEvents,
      reason:
          'every write threw and the report counts ${report.failedApplies} of '
          'them — a merge that reports success with nothing written is the one '
          'outcome a person cannot act on',
    );
  });

  test('an import stops when the identity it belongs to is switched away', () async {
    // The appliers are an app-wide registry that a switch re-populates, so an
    // import that ran on past one sent the REST of somebody's archive into the
    // identity they had just moved to (report27 X02).
    final archive = await _exportOf(_deviceWithHistory());
    final target = _Space();
    final collector = _Collector();

    // What a full import applies, for comparison.
    final wholeTarget = _Space();
    final wholeCollector = _Collector();
    final whole = await DataImporter(
      storage: wholeTarget,
      appliers: wholeCollector.appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));
    expect(whole.syncEvents, greaterThan(3), reason: 'nothing to cut short');

    var records = 0;
    final report = await DataImporter(
      storage: target,
      appliers: collector.appliers,
      selfNodeIdHex: hexOf(1),
    ).run(
      bytes: Stream.value(archive),
      // Ours for the first three records, somebody else's after that.
      stillOurs: () => ++records <= 3,
    );

    expect(
      report.syncEvents,
      lessThan(whole.syncEvents),
      reason: 'the rest of the archive went into the identity switched TO',
    );
    expect(report.syncEvents, lessThanOrEqualTo(3));
    expect(
      collector.events.length,
      lessThan(wholeCollector.events.length),
      reason: 'the appliers kept receiving records after the switch',
    );
  });

  test('an archive never outranks what a live device already decided', () async {
    // The exporter stamped mirrored settings and contact status with the
    // moment of EXPORT, so importing an archive from a device that had been
    // offline for a month made every stale value the newest the fold had seen:
    // `accepted` could go back to `blocked`, with nothing said (report27 X05).
    // Nothing records when a status was actually decided, so the archive's
    // events carry an order, not a clock — and lose to every real one.
    final archive = await _exportOf(_deviceWithHistory());
    final reader = await DataTransferReader.open(Stream.value(archive));
    final stamps = <int>[];
    await for (final record in reader.records()) {
      if (record.kind != TransferRecordKind.sync) continue;
      final body = jsonDecode(record.meta['b'] as String) as Map;
      final kind = body['k'];
      if (kind != 'settingSet' && kind != 'contactUp') continue;
      stamps.add(body['ts'] as int);
    }

    expect(stamps, isNotEmpty, reason: 'nothing was exported to check');
    // 5000 is this harness's export clock; a real device stamps in
    // milliseconds since 1970. Either would outrank a live decision.
    expect(
      stamps.every((ts) => ts < 5000),
      isTrue,
      reason:
          'an archived setting or contact status can overwrite a newer one '
          'on the device it is imported into',
    );
    // And the order WITHIN the archive still holds, or two events about one
    // key fold in the wrong order.
    expect(stamps, equals([...stamps]..sort()));
  });

  test('everything the device holds leaves as events the other side knows', () async {
    final archive = await _exportOf(_deviceWithHistory());

    final target = _Space();
    final collector = _Collector();
    final report = await DataImporter(
      storage: target,
      appliers: collector.appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));

    final kinds = collector.events.map((e) => e.kind).toSet();
    expect(kinds, contains(DeviceSyncKind.msgMirror));
    expect(kinds, contains(DeviceSyncKind.contactUp));
    expect(kinds, contains(DeviceSyncKind.readMark));
    expect(kinds, contains(DeviceSyncKind.callLog));
    expect(kinds, contains(DeviceSyncKind.settingSet));

    // Both messages, keyed by message id and stamped with their own time —
    // which is what lets the receiving side order them against its own.
    final mirrors = collector.events
        .where((e) => e.kind == DeviceSyncKind.msgMirror)
        .toList();
    expect(mirrors.map((e) => e.key).toSet(), {'m1', 'm2'});
    expect(mirrors.firstWhere((e) => e.key == 'm2').tsMs, 2000);

    // Contacts travel under TWO keys — preferences under the peer's id and
    // the relationship status under 's:<id>' — exactly as the live emit does,
    // so an alias edit and a block cannot overwrite one another. Asserted by
    // the KEY, because an event of the right KIND with the wrong key is the
    // shape this got wrong: a literal 's:$peerHex' put every contact in one
    // slot, where the fold keeps one of them.
    final contactKeys = collector.events
        .where((e) => e.kind == DeviceSyncKind.contactUp)
        .map((e) => e.key)
        .toSet();
    final peerHex = hexOf(3);
    expect(contactKeys, contains(peerHex));
    expect(contactKeys, contains('s:$peerHex'));
    for (final key in contactKeys) {
      expect(
        key,
        isNot(contains(r'$')),
        reason: 'a key that still holds a template is not a key',
      );
    }

    // The read mark carries the WATERMARK, not the export time.
    final mark = collector.events.firstWhere(
      (e) => e.kind == DeviceSyncKind.readMark,
    );
    expect(mark.tsMs, 2000);

    // A synced setting travels as an event; a machine-local one does not, and
    // an identity-level one lands as a setting the target did not have.
    expect(
      collector.events
          .where((e) => e.kind == DeviceSyncKind.settingSet)
          .map((e) => e.key),
      ['locale'],
    );
    expect(target.settings['nickname:claimed'], contains('ann'));
    // A window size belongs to the machine it was measured on. It used to
    // travel — every non-synced key did — and carrying it would point one
    // device at another device's idea of its own screen.
    expect(target.settings['window_width'], isNull);

    expect(target.files['file-1'], isNotNull);
    expect(utf8.decode(target.files['file-1']!), 'an attachment');
    expect(report.filesAdded, 1);
    expect(report.profileFilled, isTrue);
    expect(target.profile?.displayName, 'Ann');
  });

  test('importing the same archive twice adds nothing the second time', () async {
    final archive = await _exportOf(_deviceWithHistory());
    final target = _Space();
    final collector = _Collector();
    final importer = DataImporter(
      storage: target,
      appliers: collector.appliers,
      selfNodeIdHex: hexOf(1),
    );

    final first = await importer.run(bytes: Stream.value(archive));
    final second = await importer.run(bytes: Stream.value(archive));

    expect(first.filesAdded, 1);
    expect(second.filesAdded, 0, reason: 'the bytes were already here');
    expect(second.filesAlreadyHere, 1);
    expect(second.settingsFilled, 0, reason: 'nothing was missing any more');
    expect(second.settingsKept, greaterThan(0));

    // The events were delivered twice, and that is fine: folded the way the
    // live path folds them, twice as many events collapse onto the same slots.
    final folded = foldDeviceSync(collector.events);
    final half = foldDeviceSync(
      collector.events.take(collector.events.length ~/ 2),
    );
    expect(
      folded.length,
      half.length,
      reason: 'a second import must converge on the same state, not double it',
    );
  });

  /// report27 X08 — groups leave in the archive and arrive on the other side.
  ///
  /// The archive used to carry conversations, settings, the call journal and
  /// files, while the screen offered to save "everything this identity has".
  /// Groups and Spaces were not in it at all, so a person who kept a backup and
  /// lost the device lost every group in it and had no way to know beforehand.
  test('groups leave in the archive and land on the other side', () async {
    final source = _Groups({
      'aa' * 32: jsonEncode({'id': 'one'}),
      'bb' * 32: jsonEncode({'id': 'two'}),
    });
    final archive = await _exportOf(_deviceWithHistory(), groups: source);

    final destination = _Groups({});
    final report = await DataImporter(
      storage: _Space(),
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
      groups: destination,
    ).run(bytes: Stream.value(archive));

    expect(
      destination.restored,
      ['one', 'two'],
      reason: 'the archive carried no groups, or the importer dropped them',
    );
    expect(report.groupsRestored, 2);
    expect(report.groupsRefused, 0);
  });

  /// A group that cannot be put back is COUNTED, never dropped in silence.
  ///
  /// A group missing afterwards looks exactly like a group the archive never
  /// carried, and the two call for opposite things from the person: try again,
  /// or stop looking.
  test('a group the far side refuses is reported, not silently lost', () async {
    final source = _Groups({
      'aa' * 32: jsonEncode({'id': 'one'}),
      'bb' * 32: jsonEncode({'id': 'two'}),
    });
    final archive = await _exportOf(_deviceWithHistory(), groups: source);

    final destination = _Groups({})..refuse.add('two');
    final refusing = await DataImporter(
      storage: _Space(),
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
      groups: destination,
    ).run(bytes: Stream.value(archive));
    expect(
      refusing.groupsRestored,
      1,
      reason: 'a group the far side refused was counted as restored',
    );
    expect(refusing.groupsRefused, 1, reason: 'a refusal must be counted');

    // And an import with no group layer at all says so too, rather than
    // reporting an archive that carried groups as one that carried none.
    final blind = await DataImporter(
      storage: _Space(),
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));
    expect(blind.groupsRestored, 0);
    expect(
      blind.groupsRefused,
      2,
      reason:
          'an import that cannot reach the group layer reported the groups as '
          'absent instead of as unapplied',
    );
  });

  /// report27 X08 — the cloud tree travels, and reaches the layer that owns it.
  ///
  /// Cloud rows ride the same `sync` record everything else does, but NO
  /// applier applies them: the bridge has an explicit arm saying the cloud
  /// services do. Handing them to the appliers anyway would have counted them
  /// as merged and dropped them.
  test('cloud rows reach the layer that claims them', () async {
    final source = _Cloud(
      {DeviceSyncKind.cloudEntry, DeviceSyncKind.cloudFolder},
      [
        _cloudRow(DeviceSyncKind.cloudEntry, 'item-1'),
        _cloudRow(DeviceSyncKind.cloudFolder, 'folder-1'),
      ],
    );
    final shares = _Cloud({DeviceSyncKind.cloudCapability}, [
      _cloudRow(DeviceSyncKind.cloudCapability, 'share-1'),
    ]);
    final archive = await _exportOf(
      _deviceWithHistory(),
      cloud: [source, shares],
    );

    final index = _Cloud({
      DeviceSyncKind.cloudEntry,
      DeviceSyncKind.cloudFolder,
    });
    final registry = _Cloud({DeviceSyncKind.cloudCapability});
    final collector = _Collector();
    final report = await DataImporter(
      storage: _Space(),
      appliers: collector.appliers,
      selfNodeIdHex: hexOf(1),
      cloud: [index, registry],
    ).run(bytes: Stream.value(archive));

    // Asked FIRST, because it is what separates "went to the wrong place"
    // from "never left": a row that reached the appliers is a row this import
    // counted as merged and dropped.
    expect(
      collector.events.map((e) => e.kind),
      isNot(contains(DeviceSyncKind.cloudEntry)),
      reason:
          'a cloud row went to the appliers, which apply none of them — it '
          'would be counted as merged and dropped',
    );
    expect(
      index.adopted.map((e) => e.key),
      ['item-1', 'folder-1'],
      reason: 'the cloud index rows did not reach the index',
    );
    expect(
      registry.adopted.map((e) => e.key),
      ['share-1'],
      reason: 'a share grant went to the wrong layer, or to none',
    );
    expect(report.cloudRowsAdopted, 3);
  });

  /// With no cloud layer wired, the rows are REFUSED, never counted as merged.
  ///
  /// The two look identical afterwards — a tree that is not there — and call
  /// for opposite things from the person.
  test('cloud rows with nobody to take them are reported, not merged', () async {
    final archive = await _exportOf(
      _deviceWithHistory(),
      cloud: [
        _Cloud({DeviceSyncKind.cloudEntry}, [
          _cloudRow(DeviceSyncKind.cloudEntry, 'item-1'),
          _cloudRow(DeviceSyncKind.cloudEntry, 'item-2'),
        ]),
      ],
    );

    final blind = await DataImporter(
      storage: _Space(),
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));
    expect(blind.cloudRowsAdopted, 0);
    expect(
      blind.cloudRowsRefused,
      2,
      reason:
          'an import with no cloud layer reported the tree as absent instead '
          'of as unapplied',
    );

    // And a layer that does not claim the kind is the same case: the row was
    // carried and nobody took it.
    final wrongLayer = await DataImporter(
      storage: _Space(),
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
      cloud: [_Cloud({DeviceSyncKind.cloudCapability})],
    ).run(bytes: Stream.value(archive));
    expect(wrongLayer.cloudRowsAdopted, 0);
    expect(
      wrongLayer.cloudRowsRefused,
      2,
      reason:
          'a row no wired layer claims was carried and nobody took it, and '
          'the report said nothing — the same silence as having no layer',
    );
  });

  test('the profile is filled, never overwritten', () async {
    final archive = await _exportOf(_deviceWithHistory());
    final target = _Space()
      ..profile = const UserProfile(displayName: 'Already Here', username: 'me');

    await DataImporter(
      storage: target,
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));

    expect(target.profile?.displayName, 'Already Here');
    expect(target.profile?.username, 'me');
  });

  test('a setting this device already has is kept', () async {
    final archive = await _exportOf(_deviceWithHistory());
    final target = _Space()..settings['nickname:claimed'] = '{"name":"mine"}';

    final report = await DataImporter(
      storage: target,
      appliers: _Collector().appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive));

    expect(target.settings['nickname:claimed'], '{"name":"mine"}');
    expect(report.settingsKept, greaterThan(0));
  });

  test('an archive from another identity is refused before anything lands', () async {
    final archive = await _exportOf(_deviceWithHistory());
    final target = _Space();

    await expectLater(
      DataImporter(
        storage: target,
        appliers: _Collector().appliers,
        selfNodeIdHex: hexOf(2), // a different identity
      ).run(bytes: Stream.value(archive)),
      throwsA(
        isA<ImportRefused>().having(
          (e) => e.reason,
          'reason',
          ImportRefusal.otherIdentity,
        ),
      ),
    );
    expect(target.files, isEmpty, reason: 'nothing may be applied on refusal');
    expect(target.settings, isEmpty);
  });

  test('an archive carrying an identity is refused by a device that has one', () async {
    final archive = await _exportOf(_deviceWithHistory(), includeIdentity: true);
    final target = _Space(nodeConfig: '[identity]\nkey = "mine"\n');

    await expectLater(
      DataImporter(
        storage: target,
        appliers: _Collector().appliers,
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(archive)),
      throwsA(
        isA<ImportRefused>().having(
          (e) => e.reason,
          'reason',
          ImportRefusal.identityWouldBeReplaced,
        ),
      ),
    );
    expect(target.nodeConfig, contains('mine'), reason: 'never replaced');
  });

  test('a fresh device adopts the identity the archive carries', () async {
    final archive = await _exportOf(_deviceWithHistory(), includeIdentity: true);
    final target = _Space();

    final report = await DataImporter(
      storage: target,
      appliers: _Collector().appliers,
      selfNodeIdHex: '', // nothing here yet
    ).run(bytes: Stream.value(archive));

    expect(report.identityAdopted, isTrue);
    expect(target.nodeConfig, contains('secret'));
  });

  group('what an identity may replace', () {
    // The refusal stands for one rule: an archive must never put ANOTHER
    // device's node key onto this one, because two devices of an identity
    // sharing a key are one node. It used to enforce that by counting — any
    // stored identity refused any archive carrying one — which is stricter
    // than the rule and strict enough to break the only route the app has for
    // restoring an identity from an archive: adopt the key on a clean install,
    // then merge the rest of the SAME file once there is a session. The second
    // step met its own first step and called it a clone.
    const toml = '[identity]\nkey = "mine"';

    Future<Uint8List> identityArchive() async {
      final out = BytesBuilder();
      final w = await DataTransferWriter.open(
        sink: (b) async => out.add(b),
        header: TransferHeader(
          createdMs: 1,
          nodeIdHex: hexOf(1),
          includesIdentity: true,
          includesFiles: false,
        ),
      );
      await w.add(
        TransferRecord(
          kind: TransferRecordKind.identity,
          payload: Uint8List.fromList(utf8.encode(toml)),
        ),
      );
      await w.close();
      return out.toBytes();
    }

    test('the key this device already runs on is adopted again as a no-op', () async {
      final bytes = await identityArchive();
      final target = _Space(nodeConfig: toml);
      final report = await DataImporter(
        storage: target,
        appliers: DeviceSyncAppliers()..register((_, {attachmentThumb}) async {}),
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(bytes));
      expect(report.identityAdopted, isTrue);
      expect(
        target.nodeConfig,
        toml,
        reason: 'nothing was replaced, so nothing may have changed',
      );
    });

    test('a DIFFERENT key for the same identity is still refused', () async {
      // The clone this guard exists for: same identity, another device's key.
      final bytes = await identityArchive();
      final target = _Space(nodeConfig: '[identity]\nkey = "another device"');
      await expectLater(
        DataImporter(
          storage: target,
          appliers: DeviceSyncAppliers()
            ..register((_, {attachmentThumb}) async {}),
          selfNodeIdHex: hexOf(1),
        ).run(bytes: Stream.value(bytes)),
        throwsA(
          isA<ImportRefused>().having(
            (e) => e.reason,
            'reason',
            ImportRefusal.identityWouldBeReplaced,
          ),
        ),
      );
      expect(target.nodeConfig, '[identity]\nkey = "another device"');
    });

    test('the identity can be read out without applying anything', () async {
      // What a clean install needs before it has a container: the key, with
      // nothing written and nothing merged.
      final bytes = await identityArchive();
      expect(
        await DataImporter.readIdentity(Stream.value(bytes)),
        toml,
      );
    });

    test('an archive with no identity reads as none, not as a failure', () async {
      final out = BytesBuilder();
      final w = await DataTransferWriter.open(
        sink: (b) async => out.add(b),
        header: TransferHeader(
          createdMs: 1,
          nodeIdHex: hexOf(1),
          includesIdentity: false,
          includesFiles: false,
        ),
      );
      await w.close();
      expect(
        await DataImporter.readIdentity(Stream.value(out.toBytes())),
        isNull,
      );
    });
  });

  group('the header is a preview, not an authority (report24 CH-W3/CH-W4)', () {
    test('an identity record in a data-only archive is refused', () async {
      // The header says keys:false; the body carries one anyway. Written by
      // hand, because the exporter cannot produce this shape — which is the
      // point: an archive is a file, and a file says what its author wrote.
      final out = BytesBuilder();
      final w = await DataTransferWriter.open(
        sink: (b) async => out.add(b),
        header: TransferHeader(
          createdMs: 1,
          nodeIdHex: hexOf(1),
          includesIdentity: false,
          includesFiles: false,
        ),
      );
      await w.add(
        TransferRecord(
          kind: TransferRecordKind.identity,
          payload: Uint8List.fromList(utf8.encode('[identity]\nkey = "theirs"')),
        ),
      );
      await w.close();

      final target = _Space(nodeConfig: '[identity]\nkey = "mine"');
      await expectLater(
        DataImporter(
          storage: target,
          appliers: _Collector().appliers,
          selfNodeIdHex: hexOf(1),
        ).run(bytes: Stream.value(out.takeBytes())),
        throwsA(isA<ImportRefused>()),
      );
      expect(
        target.nodeConfig,
        contains('mine'),
        reason: 'the identity in use may never be overwritten by a file',
      );
    });

    test('a fresh device still refuses an identity the header did not declare',
        () async {
      final out = BytesBuilder();
      final w = await DataTransferWriter.open(
        sink: (b) async => out.add(b),
        header: TransferHeader(
          createdMs: 1,
          nodeIdHex: hexOf(1),
          includesIdentity: false, // the lie
          includesFiles: false,
        ),
      );
      await w.add(
        TransferRecord(
          kind: TransferRecordKind.identity,
          payload: Uint8List.fromList(utf8.encode('[identity]\nkey = "x"')),
        ),
      );
      await w.close();

      final target = _Space(); // nothing here at all
      await expectLater(
        DataImporter(
          storage: target,
          appliers: _Collector().appliers,
          selfNodeIdHex: '',
        ).run(bytes: Stream.value(out.takeBytes())),
        throwsA(isA<ImportRefused>()),
      );
      expect(target.nodeConfig, isNull);
    });

    test('a settings record cannot plant key material', () async {
      final out = BytesBuilder();
      final w = await DataTransferWriter.open(
        sink: (b) async => out.add(b),
        header: TransferHeader(
          createdMs: 1,
          nodeIdHex: hexOf(1),
          includesIdentity: false,
          includesFiles: false,
        ),
      );
      // The key that holds base64 master signing material, absent locally —
      // so no overwrite is needed, only a gap to fill.
      await w.add(
        const TransferRecord(
          kind: TransferRecordKind.setting,
          meta: {'key': 'node.master_key.v1', 'v': 'INJECTED'},
        ),
      );
      await w.add(
        const TransferRecord(
          kind: TransferRecordKind.setting,
          meta: {'key': 'ratchet.local_instance.v1', 'v': 'INJECTED'},
        ),
      );
      await w.close();

      final target = _Space();
      final report = await DataImporter(
        storage: target,
        appliers: _Collector().appliers,
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(out.takeBytes()));

      expect(target.settings['node.master_key.v1'], isNull);
      expect(target.settings['ratchet.local_instance.v1'], isNull);
      expect(report.settingsFilled, 0);
      expect(report.settingsRefused, 2, reason: 'refused, and said so');
    });

    test('the exporter does not write what the importer would refuse', () async {
      final space = _deviceWithHistory();
      space.settings['node.master_key.v1'] = 'SECRET';
      space.settings['ratchet.local_instance.v1'] = 'STATE';

      final archive = await _exportOf(space);
      final target = _Space();
      final report = await DataImporter(
        storage: target,
        appliers: _Collector().appliers,
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(archive));

      expect(
        utf8.decode(archive, allowMalformed: true),
        isNot(contains('SECRET')),
        reason: 'key material must not be in the file at all',
      );
      expect(report.settingsRefused, 0, reason: 'nothing to refuse on arrival');
      expect(target.settings['nickname:claimed'], isNotNull);
    });
  });

  test('an import with nothing listening is refused, not reported as done', () async {
    final archive = await _exportOf(_deviceWithHistory());

    await expectLater(
      DataImporter(
        storage: _Space(),
        appliers: DeviceSyncAppliers(), // nobody registered
        selfNodeIdHex: hexOf(1),
      ).run(bytes: Stream.value(archive)),
      throwsA(
        isA<ImportRefused>().having(
          (e) => e.reason,
          'reason',
          ImportRefusal.noAppliers,
        ),
      ),
    );
  });

  test('a sealed archive round-trips through the same merge', () async {
    final archive = await _exportOf(_deviceWithHistory(), password: 'pw');
    final target = _Space();
    final collector = _Collector();

    final report = await DataImporter(
      storage: target,
      appliers: collector.appliers,
      selfNodeIdHex: hexOf(1),
    ).run(bytes: Stream.value(archive), password: 'pw');

    expect(report.syncEvents, greaterThan(0));
    expect(utf8.decode(target.files['file-1']!), 'an attachment');
  });

  test('the plan counts what an export would carry, before it runs', () async {
    final plan = await DataExporter(
      storage: _deviceWithHistory(),
      nodeIdHex: hexOf(1),
      syncedSettingKeys: {'locale'},
    ).plan();

    // Only the settings that actually travel: the space also holds
    // `window_width`, which is this machine's, and the count used to include
    // it (report24 CH-W1).
    expect(plan.settings, 2, reason: 'locale (synced) + nickname:claimed');
    expect(plan.contacts, 1);
    expect(plan.messages, 2);
    expect(plan.callLogEntries, 1);
    expect(plan.files, 1);
    expect(plan.fileBytes, 13);
    expect(plan.estimatedBytesWithFiles, greaterThan(plan.estimatedBytesWithoutFiles));
  });

  group('the credential travels with the identity', () {
    // THE THIRD PLACE THE SAME ROOT SHOWED UP. The exporter wrote the node
    // config and the header called it "keys". But the address a person's
    // contacts hold comes from the hybrid master in the sovereign credential,
    // whose Falcon half is reproducible from nothing at all — so an archive
    // without it restored a device that talks on the right wire key and
    // answers where nobody writes. Measured in the field: "восстановилась
    // другая личность (другой node_id)".
    Uint8List credentialBytes() =>
        Uint8List.fromList(ascii.encode('XVSB') + List<int>.filled(120, 3));

    _Space deviceWithCredential() {
      final space = _deviceWithHistory();
      space.files[kSovereignBundleSetting] = credentialBytes();
      return space;
    }

    test('an identity export carries it, and a fresh device takes it', () async {
      final archive = await _exportOf(
        deviceWithCredential(),
        includeIdentity: true,
      );
      expect(
        await DataImporter.readCredential(Stream.value(archive)),
        credentialBytes(),
        reason: 'the archive has to hold the key the identity is named by',
      );

      final target = _Space();
      final report = await DataImporter(
        storage: target,
        appliers: _Collector().appliers,
        selfNodeIdHex: '',
      ).run(bytes: Stream.value(archive));

      expect(report.credentialAdopted, isTrue);
      expect(target.files[kSovereignBundleSetting], credentialBytes());
    });

    test('an export without the identity carries no credential', () async {
      // The control. `includeIdentity: false` is a person choosing to hand
      // over their conversations and not their identity, and the credential is
      // the most identity-shaped thing in the container.
      final archive = await _exportOf(deviceWithCredential());
      expect(await DataImporter.readCredential(Stream.value(archive)), isNull);
    });

    test('another identity credential is refused, not adopted over', () async {
      final archive = await _exportOf(
        deviceWithCredential(),
        includeIdentity: true,
      );
      final target = _Space();
      target.files[kSovereignBundleSetting] = Uint8List.fromList(
        ascii.encode('XVSB') + List<int>.filled(120, 9),
      );
      await expectLater(
        DataImporter(
          storage: target,
          appliers: _Collector().appliers,
          selfNodeIdHex: '',
        ).run(bytes: Stream.value(archive)),
        throwsA(isA<ImportRefused>()),
      );
      expect(
        target.files[kSovereignBundleSetting]!.last,
        9,
        reason: 'the credential this device runs on must survive the refusal',
      );
    });
  });
}
