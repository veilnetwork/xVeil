@Timeout(Duration(minutes: 2))
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
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';
import 'package:xveil/state/messaging.dart';

import '../support/timed_native_store.dart';

class _ExpiryStore extends TimedNativeStore {
  _ExpiryStore(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  bool refuse = false, uncertain = false;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final expired = ops.whereType<AppendLogOp>().any(
      (op) =>
          op.namespace >= Ns.messageLogShardFirst &&
          op.namespace <= Ns.messageLogShardLast &&
          (jsonDecode(utf8.decode(op.payload)) as Map)['op'] == 'del',
    );
    if (expired && refuse) {
      refuse = false;
      throw StateError('before expiry commit');
    }
    final result = await super.commit(ops);
    if (expired && uncertain) {
      uncertain = false;
      throw StateError('lost expiry commit response');
    }
    return result;
  }
}

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  final enabled = native?.isNotEmpty ?? false;
  final skip = enabled
      ? false
      : 'set XVEIL_HV_DYLIB to a qualified native library';
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  final sibling = NodeId(Uint8List(32)..fillRange(0, 32, 3));
  final now = DateTime.utc(2026, 11, 4, 12);
  const passwordText = 'expiry-native-fixture';
  final password = Uint8List.fromList(utf8.encode(passwordText));
  late Directory directory;
  late HiddenVolumeStorage storage;
  late _ExpiryStore backing;
  late MessagingService messaging;

  Future<void> open() async {
    backing = _ExpiryStore(
      (await workerSpaceOpener('${directory.path}/store.hv')(
        password: password,
        create: false,
      ))!,
    );
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    expect(await storage.open(password: passwordText), isTrue);
    messaging = MessagingService(
      LoopbackTransport(
        localNodeId: NodeId(Uint8List(32)..fillRange(0, 32, 1)),
      ),
      storage,
      now: () => now,
    );
    messaging.groupBindingsOwner = Object();
    messaging.myOtherDevices = () async => [sibling];
  }

  Future<void> close() async {
    await messaging.dispose();
    await storage.close();
  }

  Future<bool> mirror() => messaging.applyMirroredMessage(
    peer: peer,
    msgId: 'expired',
    direction: MessageDirection.incoming,
    body: 'PRIVATE_EXPIRED_BODY',
    tsMs: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
    author: peer.hex,
    seq: 1,
    positionVerified: true,
  );

  setUp(() async {
    if (!enabled) return;
    expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
    directory = await Directory.systemTemp.createTemp('xveil-expiry-native-');
    HvKvLogStore(
      hv.HvSpace.create(
        path: '${directory.path}/store.hv',
        password: password,
        argon: hv.ArgonPreset.light,
      ),
    ).close();
    await open();
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
  });
  tearDown(() async {
    if (!enabled) return;
    await close();
    await directory.delete(recursive: true);
  });

  test(
    'native expiry writes a bodyless durable gap slot and prevents replay after TTL off',
    () async {
      expect(await mirror(), isFalse);
      expect(await storage.isMessageDeleted(peer.hex, 'expired'), isTrue);
      expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 1);
      final events = await storage.loadEventsSince(peer.hex, peer.hex, 0);
      expect(events.single.kind, EventKind.void_);
      expect(events.single.body, isNull);
      for (
        var ns = Ns.messageLogShardFirst;
        ns <= Ns.messageLogShardLast;
        ns++
      ) {
        final rows = await backing.iterLogRange(namespace: ns, limit: 8192);
        expect(
          rows.any(
            (row) => utf8.decode(row.payload).contains('PRIVATE_EXPIRED_BODY'),
          ),
          isFalse,
        );
      }
      await storage.upsertContact(
        (await storage.getContact(
          peer,
        ))!.copyWith(disappearingTtlSeconds: null),
      );
      await close();
      await open();
      expect(await mirror(), isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(await storage.pendingMessageDeletions(), isEmpty);
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test(
      'native expiry retries storage failure without storing a body ($uncertain)',
      () async {
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        await expectLater(mirror(), throwsStateError);
        expect(await storage.isMessageDeleted(peer.hex, 'expired'), uncertain);
        expect(await mirror(), isFalse);
        await close();
        await open();
        expect(await storage.isMessageDeleted(peer.hex, 'expired'), isTrue);
        expect(await storage.loadMessages(peer.hex), isEmpty);
        expect(
          (await storage.loadEventsSince(peer.hex, peer.hex, 0)),
          hasLength(1),
        );
      },
      skip: skip,
    );
  }

  test(
    'native expiry compare does not erase an already-held live row',
    () async {
      await storage.appendMessage(
        Message(
          id: 'held',
          conversationId: peer.hex,
          direction: MessageDirection.incoming,
          body: 'live',
          timestamp: now,
          author: peer.hex,
          seq: 1,
        ),
      );
      expect(
        await storage.recordExpiredMessage(
          peer.hex,
          'held',
          author: peer.hex,
          seq: 1,
        ),
        isFalse,
      );
      expect((await storage.loadMessageById(peer.hex, 'held'))!.body, 'live');
    },
    skip: skip,
  );
}
