@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
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
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

class _GatedStorage extends HiddenVolumeStorage {
  _GatedStorage(String path) : super.async(workerSpaceOpener(path));
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<int> pruneConversationBefore(NodeId peer, DateTime cutoff) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.pruneConversationBefore(peer, cutoff);
  }
}

void main() {
  final dylib = Platform.environment['XVEIL_HV_DYLIB'];
  test(
    'startup erasure at exact TTL drains before native close and survives reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(dylibPath: dylib), isTrue);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-startup-expiry-native-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/store.hv';
      final password = Uint8List.fromList(utf8.encode('fixture'));
      HvKvLogStore(
        hv.HvSpace.create(
          path: path,
          password: password,
          argon: hv.ArgonPreset.light,
        ),
      ).close();
      final store = _GatedStorage(path);
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        await store.close();
      });
      expect(await store.open(password: 'fixture'), isTrue);
      final peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
      final now = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
      );
      final cutoff = now.subtract(const Duration(seconds: 30));
      await store.upsertContact(
        Contact(
          nodeId: peer,
          status: ContactStatus.accepted,
          disappearingTtlSeconds: 30,
        ),
      );
      for (final entry in [
        ('expired', cutoff),
        ('fresh', cutoff.add(const Duration(milliseconds: 1))),
      ]) {
        await store.appendMessage(
          Message(
            id: entry.$1,
            conversationId: peer.hex,
            direction: MessageDirection.incoming,
            body: entry.$1 == 'expired'
                ? 'NATIVE_EXPIRED_STARTUP'
                : 'NATIVE_FRESH_STARTUP',
            timestamp: entry.$2,
            author: peer.hex,
          ),
        );
      }
      expect((await store.loadMessages(peer.hex)).length, 2);
      final transport = LoopbackTransport();
      final messaging = MessagingService(transport, store, now: () => now);
      var linkClosed = false;
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        await messaging.dispose();
        if (!linkClosed) await transport.dispose();
      });
      messaging.start();
      await store.entered.future.timeout(const Duration(seconds: 10));
      var closed = false;
      final closing = messaging.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      store.release.complete();
      await closing;
      linkClosed = true;
      await transport.dispose();
      await store.close();
      final raw = (await workerSpaceOpener(path)(
        password: password,
        create: false,
      ))!;
      try {
        var oldBodies = 0, freshBodies = 0;
        for (
          var ns = Ns.messageLogShardFirst;
          ns <= Ns.messageLogShardLast;
          ns++
        ) {
          for (final row in await raw.iterLogRange(
            namespace: ns,
            limit: 8192,
          )) {
            final text = utf8.decode(row.payload, allowMalformed: true);
            if (text.contains('NATIVE_EXPIRED_STARTUP')) oldBodies++;
            if (text.contains('NATIVE_FRESH_STARTUP')) freshBodies++;
          }
        }
        expect(oldBodies, 0);
        expect(freshBodies, 1);
      } finally {
        await raw.close();
      }
      expect(await store.open(password: 'fixture'), isTrue);
      expect(await store.isMessageDeleted(peer.hex, 'expired'), isTrue);
      expect((await store.loadMessages(peer.hex)).single.id, 'fresh');
    },
    skip: dylib == null ? 'set XVEIL_HV_DYLIB to a qualified library' : false,
  );
}
