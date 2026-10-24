import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Store extends HvKvLogStore {
  _Store(this.space) : super(space);
  final hv.HvSpace space;
  int scrubs = 0, reclaimed = 0;
  @override
  void scrub() {
    scrubs++;
    reclaimed += space.vacuumDataBatches();
  }
}

void main() {
  final enabled = Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false;
  final available = enabled && ensureHiddenVolumeLoaded();
  for (final mode in ['password', 'keys', 'async-view']) {
    test(
      'real legacy shared data batch is reclaimed once through $mode',
      () async {
        final dir = Directory.systemTemp.createTempSync('xveil-legacy-scrub-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/fixture.hv',
            password = _bytes('fixture-password');
        var raw = _Store(
          hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.min,
          ),
        );
        final keys = raw.exportKeys();
        const ns = Ns.messageLogShardFirst, peer = 'fixture-peer';
        Map<String, Object> post(String id, String body, int seq) => {
          'id': id,
          'c': peer,
          'd': 0,
          'b': body,
          't': 1000 + seq,
          's': 0,
          'au': peer,
          'sq': seq,
        };
        // Both messages share an original DataBatch. Replacing one log id
        // leaves its prior bytes in the batch still referenced by the live row.
        raw.commit([
          AppendLogOp(
            ns,
            1,
            _bytes(jsonEncode(post('old-target', 'legacy secret body', 1))),
          ),
          AppendLogOp(
            ns,
            2,
            _bytes(jsonEncode(post('live', 'preserved fixture body', 2))),
          ),
          PutOp(Ns.settings, _bytes('msg_next_id'), _bytes('3')),
          PutOp(Ns.settings, _bytes('msglog_ns:v1:$ns'), _bytes('$ns')),
        ]);
        raw.commit([
          AppendLogOp(
            ns,
            1,
            _bytes(
              jsonEncode({
                'op': 'del',
                'id': 'old-target',
                'c': peer,
                'au': peer,
                'sq': 1,
              }),
            ),
          ),
        ]);
        raw.close();
        raw = _Store(
          mode == 'keys'
              ? hv.HvSpace.openWithKeys(path: path, keys: keys)
              : hv.HvSpace.open(path: path, password: password),
        );
        final storage = mode == 'async-view'
            ? HiddenVolumeStorage.fromAsyncStore(
                SyncWrappedAsyncKvLogStore(raw),
              )
            : HiddenVolumeStorage(
                ({required Uint8List password, required bool create}) => raw,
                keysOpener: (_) => raw,
              );
        addTearDown(() async {
          if (storage.isOpen) await storage.close();
        });
        if (mode == 'password') {
          await storage.open(password: 'fixture-password');
        }
        if (mode == 'keys') await storage.openWithKeys(keys);
        expect(await storage.isMessageDeleted(peer, 'old-target'), isTrue);
        expect(raw.scrubs, 1);
        expect(raw.reclaimed, greaterThan(0));
        expect(
          (await storage.loadMessages(peer)).single.body,
          'preserved fixture body',
        );
        raw.space.verifyIntegrity();
        await storage.close();

        final cleanRaw = _Store(
          hv.HvSpace.open(path: path, password: password),
        );
        final clean = HiddenVolumeStorage.fromStore(cleanRaw);
        addTearDown(clean.close);
        expect((await clean.loadMessages(peer)).single.id, 'live');
        expect(cleanRaw.scrubs, 0);
        cleanRaw.space.verifyIntegrity();
      },
      skip: available
          ? null
          : 'set XVEIL_HV_DYLIB to a verified current library',
    );
  }
}
