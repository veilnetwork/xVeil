import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/chat.dart';

class _CountingNativeStore extends HvKvLogStore {
  _CountingNativeStore(super.space);
  final logStarts = <int?>[];
  int scrubs = 0;

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    logStarts.add(start);
    return super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }

  @override
  void scrub() {
    super.scrub();
    scrubs++;
  }
}

void main() {
  test(
    'native ratchet vacuum preserves live log IDs and the warm message fold',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xveil-ratchet-fold-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final space = hv.HvSpace.create(
        path: '${directory.path}/fixture.hv',
        password: Uint8List.fromList(utf8.encode('fixture-password')),
        argon: hv.ArgonPreset.light,
      );
      final raw = _CountingNativeStore(space);
      final storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) => raw,
      );
      await storage.open(password: 'fixture-password', createIfMissing: false);
      addTearDown(storage.close);
      Message row(int i) => Message(
        id: 'fixture-$i',
        conversationId: 'fixture-peer',
        direction: MessageDirection.outgoing,
        author: 'fixture-author',
        body: 'body-$i',
        seq: i + 1,
        timestamp: DateTime.utc(2020).add(Duration(seconds: i)),
        status: MessageStatus.sent,
      );
      for (var i = 0; i < 200; i++) {
        await storage.appendMessage(row(i));
      }
      expect(await storage.loadMessages('fixture-peer'), hasLength(200));
      final before = raw.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 512,
      );
      expect(before, hasLength(200));
      raw.logStarts.clear();
      final key = Uint8List(64)..fillRange(0, 64, 3);
      for (var i = 0; i < 128; i++) {
        await storage.saveRatchetStates([
          RatchetStateEntry(key, Uint8List(1400)..[0] = i),
        ]);
      }
      expect(raw.scrubs, 1);
      expect(await storage.loadMessages('fixture-peer'), hasLength(200));
      expect(raw.logStarts, isEmpty);
      final after = raw.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 512,
      );
      expect(after.map((r) => r.logId), before.map((r) => r.logId));
      expect(after.map((r) => r.payload), before.map((r) => r.payload));
      raw.logStarts.clear();
      await storage.appendMessage(row(200));
      expect(await storage.loadMessages('fixture-peer'), hasLength(201));
      expect(raw.logStarts, isNotEmpty);
      expect(
        raw.logStarts.every((start) => start != null && start > 0),
        isTrue,
      );
      expect(await storage.loadRatchetState(key), Uint8List(1400)..[0] = 127);
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the production hidden-volume library',
  );
}
