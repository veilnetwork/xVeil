import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/media_object.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/sticker_device_sync.dart';
import 'package:xveil/state/sticker_store.dart';

import 'support/fake_hv_container.dart';

Future<
  ({
    ProviderContainer container,
    Storage storage,
    StickerController stickers,
    StickerDeviceSync sync,
    List<DeviceSyncEvent> posted,
    void Function(bool) allowPost,
    void Function(Future<void> Function()?) delayNextPost,
  })
>
_fixture() async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  final container = ProviderContainer(
    overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
  );
  final stickers = container.read(stickerControllerProvider.notifier);
  await container.read(stickerControllerProvider.future);
  final posted = <DeviceSyncEvent>[];
  var accepts = true;
  var timestamp = 0;
  Future<void> Function()? nextPostDelay;
  final sync = StickerDeviceSync(
    storage: storage,
    stickers: stickers,
    registerContent: (Uint8List blob) async =>
        ContentManifest.fromBytes(stickerPackSyncFileName, blob).contentId,
    postEvent: (event, {MediaObject? attachment}) async {
      final delay = nextPostDelay;
      nextPostDelay = null;
      if (delay != null) await delay();
      posted.add(event);
      return accepts;
    },
    nextTimestamp: () => ++timestamp,
  );
  return (
    container: container,
    storage: storage,
    stickers: stickers,
    sync: sync,
    posted: posted,
    allowPost: (value) => accepts = value,
    delayNextPost: (delay) => nextPostDelay = delay,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('renaming an empty pack reaches the other device', () async {
    final f = await _fixture();
    addTearDown(f.container.dispose);
    final id = await f.stickers.createPack('First');
    await f.sync.emit(id);
    expect(f.posted.single.payload, {'name': 'First'});

    await f.stickers.renamePack(id, 'Second');
    await f.sync.reconcile();
    expect(f.posted.last.payload, {'name': 'Second'});
    expect(f.posted, hasLength(2));
    expect(await f.sync.isOwnEcho(id, 'First', null), isFalse);
    expect(await f.sync.isOwnEcho(id, 'Second', null), isTrue);
  });

  test('a pack with images uses the same content id as its event', () async {
    final f = await _fixture();
    addTearDown(f.container.dispose);
    final id = await f.stickers.createPack('Images');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9'
      'awAAAABJRU5ErkJggg==',
    );
    expect(await f.stickers.importImages([png], packId: id), 1);
    await f.sync.emit(id);
    final cid = f.posted.single.payload['cid'] as String;
    expect(cid, isNotEmpty);
    expect(await f.sync.isOwnEcho(id, 'Images', cid), isTrue);
    await f.sync.reconcile();
    expect(f.posted, hasLength(1));

    await f.stickers.renamePack(id, 'Renamed');
    await f.sync.reconcile();
    expect(f.posted.last.payload['name'], 'Renamed');
    expect(f.posted.last.payload['cid'], isNot(cid));
    expect(f.posted, hasLength(2));
  });

  test('a refused post stays pending and is retried at startup', () async {
    final f = await _fixture();
    addTearDown(f.container.dispose);
    final id = await f.stickers.createPack('Later');
    f.allowPost(false);
    await f.sync.emit(id);
    expect(
      await f.storage.getSetting('stickers.announced.v1:$id'),
      startsWith('pending:'),
    );
    f.allowPost(true);
    await f.sync.reconcile();
    expect(f.posted, hasLength(2));
    expect(
      await f.storage.getSetting('stickers.announced.v1:$id'),
      startsWith('v2:'),
    );
    await f.sync.reconcile();
    expect(f.posted, hasLength(2), reason: 'an unchanged pack was reannounced');
  });

  test(
    'a deletion interrupted before its callback is repaired at startup',
    () async {
      final f = await _fixture();
      addTearDown(f.container.dispose);
      final id = await f.stickers.createPack('Temporary');
      await f.sync.emit(id);
      await f.stickers.deletePack(id); // no emit: the app stopped here

      await f.sync.reconcile();
      expect(f.posted.last.kind, DeviceSyncKind.stickerPack);
      expect(f.posted.last.key, id);
      expect(f.posted.last.payload, {'del': true});
      await f.sync.reconcile();
      expect(f.posted, hasLength(2));
    },
  );

  test('edits of one pack are posted in order', () async {
    final f = await _fixture();
    addTearDown(f.container.dispose);
    final id = await f.stickers.createPack('First');
    await f.sync.emit(id);
    final entered = Completer<void>();
    final release = Completer<void>();
    f.delayNextPost(() {
      entered.complete();
      return release.future;
    });
    await f.stickers.renamePack(id, 'Second');
    final second = f.sync.emit(id);
    await entered.future;
    await f.stickers.renamePack(id, 'Third');
    final third = f.sync.emit(id);
    expect(f.posted, hasLength(1));
    release.complete();
    await Future.wait([second, third]);
    expect(
      [for (final event in f.posted) event.payload['name']],
      ['First', 'Second', 'Third'],
    );
    await f.sync.reconcile();
    expect(f.posted.last.payload['name'], 'Third');
  });

  test(
    'a legacy marker is adopted without reannouncing a stale pack',
    () async {
      final f = await _fixture();
      addTearDown(f.container.dispose);
      final id = await f.stickers.createPack('Existing');
      await f.storage.putSetting('stickers.announced.v1:$id', '');
      await f.sync.reconcile();
      expect(f.posted, isEmpty);
      expect(
        await f.storage.getSetting('stickers.announced.v1:$id'),
        startsWith('v2:'),
      );
    },
  );
}
