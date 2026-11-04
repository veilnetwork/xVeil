@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import '../support/queued_snapshot_probe.dart';

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  test(
    'expired direct edit disappears from stopped native roots before reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-expired-edit-native-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/store.hv';
      HvKvLogStore(
        hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList(utf8.encode('fixture')),
          argon: hv.ArgonPreset.light,
        ),
      ).close();
      final opener = workerSpaceOpener(path);
      final storage = HiddenVolumeStorage.async(opener);
      addTearDown(storage.close);
      final me = NodeId(Uint8List(32)..fillRange(0, 32, 1));
      final peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
      var now = DateTime.now();
      await storage.open(password: 'fixture');
      await storage.upsertContact(
        Contact(
          nodeId: peer,
          status: ContactStatus.accepted,
          disappearingTtlSeconds: 30,
        ),
      );
      await storage.appendMessage(
        Message(
          id: 'target',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'original',
          timestamp: now,
          author: me.hex,
          seq: 1,
        ),
      );
      final seq = await storage.editMessage(
        peer.hex,
        'target',
        'NATIVE_EXPIRED_EDIT',
      );
      expect(seq, isNotNull);
      final transport = LoopbackTransport(localNodeId: me);
      final messaging = MessagingService(transport, storage, now: () => now);
      await messaging.sendDurable(
        peer,
        'edit:native',
        WireEnvelope.edit('target', 'NATIVE_EXPIRED_EDIT', seq: seq),
      );
      await messaging.dispose();
      await transport.dispose();
      await storage.close();
      Future<List<WireEnvelope>> inspect() async {
        final raw = (await opener(
          password: Uint8List.fromList(utf8.encode('fixture')),
          create: false,
        ))!;
        try {
          final frames = <OutboxFrame>[];
          final stats = await stoppedOutboxStats(
            raw,
            'ab' * 32,
            {},
            keepKey: 'unused',
            inspectFrames: frames.addAll,
          );
          expect(stats['orphanPayloadRows'], 0);
          expect(stats['cleanupPending'], 0);
          return frames.map((f) => WireEnvelope.decode(f.wire)).toList();
        } finally {
          await raw.close();
        }
      }

      final before = await inspect();
      expect(before.single.body, 'NATIVE_EXPIRED_EDIT');
      expect(before.single.kind, WireKind.edit);
      expect(await storage.open(password: 'fixture'), isTrue);
      now = now.add(const Duration(seconds: 31));
      final nextTransport = LoopbackTransport(localNodeId: me);
      final next = MessagingService(nextTransport, storage, now: () => now);
      try {
        await next.sweepAllDisappearing();
        expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
      } finally {
        await next.dispose();
        await nextTransport.dispose();
        await storage.close();
      }
      final after = await inspect();
      expect(after.single.kind, WireKind.voidSeq);
      expect(after.single.seq, seq);
      expect(after.single.id, isNull);
      expect(after.single.body, isEmpty);
      expect(await storage.open(password: 'fixture'), isTrue);
      expect(
        (await storage.pendingOutboxFrames()).single.wire,
        after.single.encode(),
      );
      expect(await storage.loadMessageById(peer.hex, 'target'), isNull);
    },
    skip: native == null ? 'set XVEIL_HV_DYLIB to a qualified library' : false,
  );
}
