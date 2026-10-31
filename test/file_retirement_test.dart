import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  test(
    'queued storage freezes hints and serializes replacement cleanup',
    () async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      addTearDown(storage.close);
      await storage.storeFile('old', _key('old bytes'));
      await storage.storeFile('header', _key('old header'));
      final hints = ['old'];
      final write = storage.storeFile(
        'header',
        _key('new header'),
        retireHints: hints,
      );
      hints.clear();
      final other = storage.storeFile('unrelated', _key('other bytes'));
      await Future.wait([write, other]);
      expect(await storage.loadFile('old'), isNull);
      expect(await storage.loadFile('header'), _key('new header'));
      expect(await storage.loadFile('unrelated'), _key('other bytes'));
      expect(
        () => storage.storeFile('header', _key('x'), retireHints: ['header']),
        throwsArgumentError,
      );
    },
  );

  test(
    'tiered hints defer all key and ciphertext cleanup to explicit delete',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xveil-retire-tier-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      addTearDown(storage.close);
      storage.useOnDiskTier(directory, minBytes: 1);
      final bytes = Uint8List.fromList(List.generate(200, (n) => n));
      await storage.storeFilePiece('tiered', 0, 1, 200, 200, bytes);
      // Even a leftover whole-file entry for the same cid must not be retired
      // separately from the tier's key and ciphertext cleanup.
      await storage.storeFile('tiered', _key('old in-volume copy'));
      raw.commit([PutOp(Ns.settings, _key('ondisk:broken'), _key('not-json'))]);
      await storage.storeFile(
        'broken',
        _key('preserve until explicit cleanup'),
      );
      final fileStore = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      final keyBefore = raw.get(Ns.settings, _key('ondisk:tiered'));
      final files = directory
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(files, isNotEmpty);
      await storage.storeFile(
        'header',
        _key('new header'),
        retireHints: ['tiered', 'broken'],
      );
      expect(await fileStore.loadFile('tiered'), _key('old in-volume copy'));
      expect(
        await fileStore.loadFile('broken'),
        _key('preserve until explicit cleanup'),
      );
      expect(raw.get(Ns.settings, _key('ondisk:tiered')), keyBefore);
      expect(raw.get(Ns.settings, _key('ondisk:broken')), _key('not-json'));
      expect(files.every((file) => file.existsSync()), isTrue);
      await storage.deleteStoredFile('tiered');
      expect(await fileStore.loadFile('tiered'), isNull);
      expect(raw.get(Ns.settings, _key('ondisk:tiered')), isNull);
      expect(files.any((file) => file.existsSync()), isFalse);
      await storage.deleteStoredFile('broken');
      expect(await fileStore.loadFile('broken'), isNull);
      // Existing explicit cleanup cannot interpret this row. The hint must
      // neither treat a failed decode as absence nor invent a tier key.
      expect(raw.get(Ns.settings, _key('ondisk:broken')), _key('not-json'));
    },
  );
}
