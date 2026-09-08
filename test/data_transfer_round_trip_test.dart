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

Future<Uint8List> _exportOf(
  _Space space, {
  String? password,
  bool includeIdentity = false,
  bool includeFiles = true,
}) async {
  final out = BytesBuilder();
  await DataExporter(
    storage: space,
    nodeIdHex: hexOf(1),
    syncedSettingKeys: {'locale'},
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
    expect(target.settings['window_width'], '900');

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

    expect(plan.contacts, 1);
    expect(plan.messages, 2);
    expect(plan.callLogEntries, 1);
    expect(plan.files, 1);
    expect(plan.fileBytes, 13);
    expect(plan.estimatedBytesWithFiles, greaterThan(plan.estimatedBytesWithoutFiles));
  });
}
