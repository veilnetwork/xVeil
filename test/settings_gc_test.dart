import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late FakeKvLogStore store;
  late HiddenVolumeStorage storage;

  setUp(() async {
    store = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => store,
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  /// Raw settings-namespace write, bypassing putSetting's `set:` prefix —
  /// models the other key families (file store, cursors).
  void seedRaw(String key, [String value = 'v']) {
    store.commit([PutOp(Ns.settings, _k(key), _k(value))]);
  }

  group('sweepSettingsGarbage', () {
    test('drops saved records for dead content', () async {
      // A live message referencing content 'cid-live'.
      await storage.appendMessage(
        Message(
          id: 'm1',
          conversationId: 'conv',
          direction: MessageDirection.incoming,
          body: 'file',
          timestamp: DateTime(2026, 7, 1),
          fileContentId: 'cid-live',
        ),
      );
      await storage.putSetting('saved:cid-live', '/tmp/live.bin');
      await storage.putSetting('saved:cid-dead', '/tmp/dead.bin');
      // Per-content serve-side bookkeeping: live cid stays, dead cid goes.
      seedRaw('file:mf:cid-live');
      seedRaw('file:mf:cid-dead');
      await storage.putSetting('served:cid-live', '{}');
      await storage.putSetting('served:cid-dead', '{}');
      seedRaw('filepiece:cid-live:0', '5');
      seedRaw('filepiece:cid-dead:0', '9');
      // Families a normal sweep must NOT touch.
      seedRaw('conv_seq:aa:bb', '7');
      seedRaw('file:record-1');

      final swept = await storage.sweepSettingsGarbage();
      expect(
        swept,
        4,
        reason: 'dead saved/served/mf/filepiece records',
      );

      final keys = await storage.settingsKeys();
      expect(keys, isNot(contains('set:saved:cid-dead')));
      expect(keys, isNot(contains('set:served:cid-dead')));
      expect(keys, isNot(contains('file:mf:cid-dead')));
      expect(keys, isNot(contains('filepiece:cid-dead:0')));
      expect(keys, contains('set:saved:cid-live'));
      expect(keys, contains('set:served:cid-live'));
      expect(keys, contains('file:mf:cid-live'));
      expect(keys, contains('filepiece:cid-live:0'));
      expect(keys, contains('conv_seq:aa:bb'));
      expect(keys, contains('file:record-1'));
      expect(await storage.getSetting('saved:cid-live'), '/tmp/live.bin');
    });

    test('derived text does not outlive the message it came from', () async {
      // A transcript and a translation are the message's own content in
      // another form. The app scrubs a deleted event's body on purpose, and
      // these survived it — so the text a person deleted stayed readable for
      // as long as the volume existed.
      await storage.appendMessage(
        Message(
          id: 'm-live',
          conversationId: 'conv',
          direction: MessageDirection.incoming,
          body: 'voice',
          timestamp: DateTime(2026, 7, 1),
          fileContentId: 'cid-live',
        ),
      );

      // Transcripts are keyed by the CONTENT id; translations by the MESSAGE.
      await storage.putSetting('voice.transcript.v3:en:cid-live', 'hello');
      await storage.putSetting('voice.transcript.v3:en:cid-dead', 'gone');
      await storage.putSetting('voice.transcript.v2:cid-live', 'legacy live');
      await storage.putSetting('voice.transcript.v2:cid-dead', 'legacy gone');
      await storage.putSetting('msg.translation.v1:en:m-live', 'hello there');
      await storage.putSetting('msg.translation.v1:en:m-dead', 'deleted text');
      await storage.putSetting('msg.translation.v1:ru:m-dead', 'удалённый текст');

      final swept = await storage.sweepSettingsGarbage();
      final keys = await storage.settingsKeys();

      // What must go: everything derived from something that is not there.
      expect(keys, isNot(contains('set:voice.transcript.v3:en:cid-dead')));
      expect(keys, isNot(contains('set:voice.transcript.v2:cid-dead')));
      expect(keys, isNot(contains('set:msg.translation.v1:en:m-dead')));
      expect(keys, isNot(contains('set:msg.translation.v1:ru:m-dead')));

      // What must STAY, which is the dangerous direction: deleting a live
      // person's translation is worse than keeping a dead one's.
      expect(keys, contains('set:voice.transcript.v3:en:cid-live'));
      expect(keys, contains('set:voice.transcript.v2:cid-live'));
      expect(keys, contains('set:msg.translation.v1:en:m-live'));
      expect(
        await storage.getSetting('msg.translation.v1:en:m-live'),
        'hello there',
      );
      expect(swept, 4);
    });

    test('a key shaped unlike its family is left alone, not guessed at',
        () async {
      // This loop's job is to delete. A malformed key is not evidence about
      // anything, and guessing at one deletes something live.
      await storage.putSetting('voice.transcript.v3:nolang', 'x');
      await storage.putSetting('msg.translation.v1:nolang', 'y');

      final swept = await storage.sweepSettingsGarbage();

      final keys = await storage.settingsKeys();
      expect(keys, contains('set:voice.transcript.v3:nolang'));
      expect(keys, contains('set:msg.translation.v1:nolang'));
      expect(swept, 0);
    });

    test('wholesale sweep drops file-store bookkeeping but keeps cursors',
        () async {
      await storage.putSetting('saved:cid-a', '/tmp/a');
      await storage.putSetting('served:cid-a', '{}');
      await storage.putSetting('gone:cid-b', '2026-07-06');
      seedRaw('file:mf:cid-a');
      seedRaw('filepiece:cid-a:0', '17');
      seedRaw('file:record-1');
      seedRaw('ondisk:cid-a'); // swept too since 78e7cab (forward secrecy:
      // no live reference -> drop the key row AND the ciphertext dir)
      seedRaw('conv_seq:aa:bb', '9');
      seedRaw('file_next_log', '42');
      seedRaw('msg_next_id', '7');
      await storage.putSetting('sync_floor:aa:bb', '3');

      final swept = await storage.sweepSettingsGarbage(wholesale: true);
      expect(swept, 7);

      final keys = await storage.settingsKeys();
      expect(keys, isNot(contains('set:saved:cid-a')));
      expect(keys, isNot(contains('set:served:cid-a')));
      expect(keys, isNot(contains('set:gone:cid-b')));
      expect(keys, isNot(contains('file:mf:cid-a')));
      expect(keys, isNot(contains('filepiece:cid-a:0')));
      expect(keys, isNot(contains('file:record-1')));
      expect(keys, isNot(contains('ondisk:cid-a')));
      expect(keys, contains('conv_seq:aa:bb'));
      expect(keys, contains('file_next_log'));
      expect(keys, contains('msg_next_id'));
      expect(keys, contains('set:sync_floor:aa:bb'));
    });

    test('sweep on a clean store is a no-op with no commits', () async {
      await storage.putSetting('theme', 'dark');
      final swept = await storage.sweepSettingsGarbage();
      expect(swept, 0);
      expect(await storage.getSetting('theme'), 'dark');
    });
  });
}
