import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

void main() {
  test(
    'large incompressible posts and edits survive reopen and deletion in native storage',
    () async {
      final dir = Directory.systemTemp.createTempSync('xveil-message-native-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.hv';
      final password = Uint8List.fromList(utf8.encode('fixture-password'));
      final random = Random(733);
      final body = base64Encode(
        List.generate(16 * 1024, (_) => random.nextInt(256)),
      );
      final edit = 'Исправление 🦊 $body';
      var space = hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      );
      var backing = HvKvLogStore(space);
      var storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture-password');
      addTearDown(() => storage.close());
      Message row(String id, String text) => Message(
        id: id,
        conversationId: 'fixture-peer',
        author: 'fixture-author',
        direction: MessageDirection.outgoing,
        body: text,
        timestamp: DateTime.utc(2026, 10, 1),
        replyToId: 'reply-target',
        forwardedFrom: 'fixture-forward',
      );
      expect((await storage.appendMessage(row('keep', 'small'))).seq, 1);
      expect((await storage.appendMessage(row('large', body))).seq, 2);
      expect(await storage.editMessage('fixture-peer', 'large', edit), 3);
      expect((await storage.loadMessages('fixture-peer')).last.body, edit);
      await storage.close();
      space = hv.HvSpace.open(path: path, password: password);
      backing = HvKvLogStore(space);
      storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture-password');
      final rows = await storage.loadMessages('fixture-peer');
      expect(rows.map((r) => r.id), ['keep', 'large']);
      expect(rows.last.body, edit);
      expect(rows.last.replyToId, 'reply-target');
      expect(rows.last.forwardedFrom, 'fixture-forward');
      expect(
        (await storage.loadMessageHistory('fixture-peer', 'large')).length,
        2,
      );
      expect(
        (await storage.loadEventsSince(
          'fixture-peer',
          'fixture-author',
          0,
        )).map((e) => e.seq),
        [1, 2, 3],
      );
      await storage.deleteMessage('fixture-peer', 'large');
      await storage.scrubDeleted();
      await storage.close();
      space = hv.HvSpace.open(path: path, password: password);
      backing = HvKvLogStore(space);
      storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture-password');
      expect((await storage.loadMessages('fixture-peer')).single.id, 'keep');
      expect(await storage.isMessageDeleted('fixture-peer', 'large'), isTrue);
      expect(
        await storage.loadMessageHistory('fixture-peer', 'large'),
        isEmpty,
      );
      for (
        var ns = Ns.messageLogShardFirst;
        ns <= Ns.messageLogShardLast;
        ns++
      ) {
        for (final entry in backing.iterLogRange(namespace: ns, limit: 8192)) {
          final raw = jsonDecode(utf8.decode(entry.payload)) as Map;
          expect(raw.containsKey('d') && raw['messagePart'] == 1, isFalse);
          expect(raw['messageParts'], isNull);
        }
      }
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the current hidden-volume library',
  );
}
