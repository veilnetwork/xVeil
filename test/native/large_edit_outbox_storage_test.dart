import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';

void main() {
  test(
    'a large valid edit and its original durable outbox frame survive native reopen',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'xveil-large-edit-native-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.hv';
      final password = Uint8List.fromList(utf8.encode('fixture-password'));
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
      await storage.appendMessage(
        Message(
          id: 'target',
          conversationId: 'fixture-peer',
          author: 'fixture-author',
          direction: MessageDirection.outgoing,
          body: 'original',
          timestamp: DateTime.utc(2026),
        ),
      );
      final random = Random(773);
      final body = base64Encode(
        List.generate(320 * 1024, (_) => random.nextInt(256)),
      );
      final revision = await storage.editMessage(
        'fixture-peer',
        'target',
        body,
      );
      final wire = WireEnvelope.edit(
        'target',
        body,
        seq: revision,
      ).withFrameId('edit:fixture').encode();
      await storage.enqueueOutboxFrame('edit:fixture', 'fixture-peer', wire);
      await storage.close();
      space = hv.HvSpace.open(path: path, password: password);
      backing = HvKvLogStore(space);
      storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture-password');
      expect((await storage.loadMessages('fixture-peer')).single.body, body);
      final queued = (await storage.pendingOutboxFrames()).single;
      expect(queued.wire, wire);
      expect(WireEnvelope.decode(queued.wire).kind, WireKind.edit);
      await storage.ackOutboxFrame('edit:fixture', fromPeerHex: 'fixture-peer');
      expect(await storage.pendingOutboxFrames(), isEmpty);
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the current hidden-volume library',
  );
}
