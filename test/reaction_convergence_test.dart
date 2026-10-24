import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/messaging_core.dart';

import 'support/fake_hv_container.dart';

NodeId id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

Future<({MessagingService messaging, Storage storage})> replica(
  int device, {
  Storage? storage,
  DateTime Function()? now,
}) async {
  final store = storage ?? FakeHvContainer().storage();
  await store.open(password: 'fixture', createIfMissing: true);
  final messaging = MessagingService(
    LoopbackTransport(localNodeId: id(device)),
    store,
    now: now,
  );
  addTearDown(store.close);
  addTearDown(messaging.dispose);
  return (messaging: messaging, storage: store);
}

class _RefusingStorage extends HiddenVolumeStorage {
  _RefusingStorage(super.opener);
  bool refuseWrites = false;
  bool refuseCleanup = false;
  @override
  Future<void> deleteStoredFile(String fileId) async {
    if (refuseCleanup) throw StateError('injected cleanup failure');
    await super.deleteStoredFile(fileId);
  }

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    if (refuseWrites) throw StateError('injected publication failure');
    await super.storeFile(fileId, bytes, name: name);
  }
}

class _CrashAfterCommit extends FakeKvLogStore {
  int? remaining;
  @override
  int commit(List<KvLogOp> ops) {
    final result = super.commit(ops);
    if (remaining != null) {
      remaining = remaining! - 1;
      if (remaining == 0) {
        throw StateError('injected crash after durable commit');
      }
    }
    return result;
  }
}

class _HeldPublication extends HiddenVolumeStorage {
  _HeldPublication(super.opener);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.storeFile(fileId, bytes, name: name);
  }
}

class _HeldContactRead extends HiddenVolumeStorage {
  _HeldContactRead(super.opener);
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Contact?> getContact(NodeId peer) async {
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.getContact(peer);
  }
}

void main() {
  final peer = id(0x44);
  test(
    'equal-stamp reactions agree with the device journal in either order',
    () async {
      final events = [
        for (final emoji in ['👍', '🚀', ''])
          DeviceSyncEvent(
            kind: DeviceSyncKind.peerReaction,
            key: '${peer.hex}|message',
            tsMs: 1000,
            payload: {'e': emoji},
          ),
      ];
      final expected = foldDeviceSync(events).values.single.payload['e'];
      for (final order in [
        events,
        events.reversed.toList(),
        [events[1], events[0], events[2]],
      ]) {
        final r = await replica(1);
        await r.storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        for (final event in order) {
          await r.messaging.applyMirroredPeerReaction(
            peer,
            'message',
            event.payload['e'] as String,
            event.tsMs,
          );
        }
        expect(
          (await r.messaging.loadReactions(peer.hex))['message']?[peer.hex] ??
              '',
          expected,
          reason:
              'equal versions must have the same winner as the shared journal',
        );
      }
    },
  );

  test(
    'parallel reaction updates retain every distinct message slot',
    () async {
      final r = await replica(1);
      await Future.wait([
        for (var index = 0; index < 12; index++)
          r.messaging.applyMirroredReaction(
            peer,
            'message-$index',
            '👍',
            1000 + index,
          ),
      ]);
      final reactions = await r.messaging.loadReactions(peer.hex);
      expect(reactions, hasLength(12));
      for (var index = 0; index < 12; index++) {
        expect(reactions['message-$index']?.values.single, '👍');
      }
    },
  );

  test('an admitted inbound reaction completes during disposal', () async {
    final store = _HeldContactRead(FakeHvContainer().passwordOpener);
    final r = await replica(1, storage: store);
    await store.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    store.hold = true;
    final delivery = r.messaging.deliverInbound(
      InboundMessage(
        src: peer,
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope.reaction(
          'message',
          '👍',
          sentAtMs: 1000,
        ).withFrameId('fixture-reaction').encode(),
      ),
    );
    await store.entered.future;
    final closing = r.messaging.dispose();
    store.release.complete();
    await delivery;
    await closing;
    expect(
      (await r.messaging.loadReactions(peer.hex))['message']?[peer.hex],
      '👍',
    );
  });

  test(
    'an admitted local reaction publishes its outbox frame during disposal',
    () async {
      final store = _HeldPublication(FakeHvContainer().passwordOpener);
      final r = await replica(1, storage: store);
      await store.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      var mirrored = 0;
      r.messaging.onReactionSent = (_, _, _, _) => mirrored++;
      final send = r.messaging.sendReaction(peer, 'message', '👍');
      await store.entered.future;
      final closing = r.messaging.dispose();
      store.release.complete();
      await send;
      await closing;
      expect(mirrored, 1);
      final frame = (await store.pendingOutboxFrames()).single;
      expect(WireEnvelope.decode(frame.wire).body, '👍');
      expect(
        (await r.messaging.loadReactions(peer.hex))['message']?.values.single,
        '👍',
      );
    },
  );

  for (final commits in [1, 2]) {
    test(
      'reopen after publication commit $commits preserves a matching value and floor',
      () async {
        final kv = _CrashAfterCommit();
        HiddenVolumeStorage storage() => HiddenVolumeStorage(
          ({required password, required bool create}) => kv,
        );
        final r = await replica(1, storage: storage());
        await r.messaging.applyMirroredReaction(peer, 'message', '👍', 1000);
        kv.remaining = commits;
        await expectLater(
          r.messaging.applyMirroredReaction(peer, 'message', '', 2000),
          throwsStateError,
        );
        kv.remaining = null;
        await r.messaging.dispose();
        await r.storage.close();
        final reopened = storage();
        await reopened.open(password: 'fixture', createIfMissing: false);
        addTearDown(reopened.close);
        final messaging = MessagingService(
          LoopbackTransport(localNodeId: id(1)),
          reopened,
        );
        addTearDown(messaging.dispose);
        final prior = (await messaging.loadReactions(
          peer.hex,
        ))['message']?.values.single;
        expect(prior, anyOf(isNull, '👍'));
        await messaging.applyMirroredReaction(peer, 'message', '🔥', 999);
        expect(
          (await messaging.loadReactions(peer.hex))['message']?.values.single,
          prior,
        );
        await messaging.applyMirroredReaction(peer, 'message', '🚀', 1500);
        expect(
          (await messaging.loadReactions(peer.hex))['message']?.values.single,
          prior == null ? null : '🚀',
        );
      },
    );
  }

  test(
    'disposal drains admitted writes before storage closes and refuses new mutations',
    () async {
      final store = _HeldPublication(FakeHvContainer().passwordOpener);
      final r = await replica(1, storage: store);
      final writes = [
        for (var i = 0; i < 12; i++)
          r.messaging.applyMirroredReaction(peer, 'message-$i', '👍', 1000 + i),
      ];
      await store.entered.future;
      var finished = false;
      final closing = r.messaging.dispose().then((_) {
        finished = true;
      });
      await expectLater(
        r.messaging.sendReaction(peer, 'new', '👍'),
        throwsStateError,
      );
      expect(finished, isFalse);
      store.release.complete();
      await Future.wait(writes);
      await closing;
      expect(await r.messaging.loadReactions(peer.hex), hasLength(12));
    },
  );

  for (final files in [false, true]) {
    test(
      'legacy ${files ? "files" : "settings"} migrate with ordering floors and tombstones',
      () async {
        final r = await replica(1);
        await r.storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        final legacy = {
          'rx:${peer.hex}': jsonEncode({
            'message': {peer.hex: '👍'},
            'other': {peer.hex: '❤️'},
          }),
          'rxat:${peer.hex}': jsonEncode({
            'message': {peer.hex: 2000},
            'other': {peer.hex: 1500},
          }),
        };
        for (final entry in legacy.entries) {
          if (files) {
            await r.storage.storeFile(
              entry.key,
              Uint8List.fromList(utf8.encode(entry.value)),
            );
          } else {
            await r.storage.putSetting(entry.key, entry.value);
          }
        }
        await r.messaging.applyMirroredPeerReaction(peer, 'message', '', 1999);
        expect(
          (await r.messaging.loadReactions(peer.hex))['message']?[peer.hex],
          '👍',
        );
        await r.messaging.applyMirroredPeerReaction(peer, 'message', '', 3000);
        for (final key in legacy.keys) {
          expect(await r.storage.loadFile(key), isNull);
          expect(await r.storage.getSetting(key), anyOf(isNull, ''));
        }
        await r.messaging.dispose();
        final reopened = MessagingService(
          LoopbackTransport(localNodeId: id(1)),
          r.storage,
        );
        addTearDown(reopened.dispose);
        await reopened.applyMirroredPeerReaction(peer, 'message', '🚀', 2500);
        final got = await reopened.loadReactions(peer.hex);
        expect(got['message'], isNull);
        expect(got['other']?[peer.hex], '❤️');
      },
    );
  }

  test(
    'failed publication preserves values/floors and does not poison the next mutation',
    () async {
      final store = _RefusingStorage(FakeHvContainer().passwordOpener);
      final r = await replica(1, storage: store);
      await r.messaging.applyMirroredReaction(peer, 'message', '👍', 1000);
      store.refuseWrites = true;
      await expectLater(
        r.messaging.applyMirroredReaction(peer, 'message', '', 2000),
        throwsStateError,
      );
      store.refuseWrites = false;
      await r.messaging.applyMirroredReaction(peer, 'message', '🚀', 1500);
      expect(
        (await r.messaging.loadReactions(peer.hex))['message']?.values.single,
        '🚀',
      );
    },
  );

  test(
    'failed legacy cleanup preserves publication and outbox, then retries',
    () async {
      final store = _RefusingStorage(FakeHvContainer().passwordOpener);
      final r = await replica(
        1,
        storage: store,
        now: () => DateTime.fromMillisecondsSinceEpoch(2000),
      );
      await store.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final key = 'rx:${peer.hex}';
      await store.storeFile(
        key,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'old': {peer.hex: '👍'},
            }),
          ),
        ),
      );
      store.refuseCleanup = true;
      await r.messaging.sendReaction(peer, 'new', '🚀');
      expect((await store.pendingOutboxFrames()).length, 1);
      expect(
        (await r.messaging.loadReactions(peer.hex)).keys,
        containsAll(['old', 'new']),
      );
      expect(await store.loadFile(key), isNotNull);
      store.refuseCleanup = false;
      await r.messaging.applyMirroredReaction(peer, 'new', '', 3000);
      expect(await store.loadFile(key), isNull);
    },
  );

  test(
    'an invalid authoritative snapshot is not overwritten from legacy fallback',
    () async {
      final r = await replica(1);
      final malformed = Uint8List.fromList(utf8.encode('{"v":99}'));
      await r.storage.storeFile('rx2:${peer.hex}', malformed);
      await expectLater(
        r.messaging.applyMirroredReaction(peer, 'message', '👍', 1000),
        throwsFormatException,
      );
      expect(await r.storage.loadFile('rx2:${peer.hex}'), malformed);
    },
  );

  test(
    'same-clock devices use distinct durable versions; local sequence survives a backward clock',
    () async {
      final first = await replica(
        1,
        now: () => DateTime.fromMillisecondsSinceEpoch(2000),
      );
      final second = await replica(
        2,
        now: () => DateTime.fromMillisecondsSinceEpoch(2000),
      );
      for (final r in [first, second]) {
        await r.storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
      }
      await first.messaging.sendReaction(peer, 'message', '👍');
      await second.messaging.sendReaction(peer, 'message', '');
      final a = (await first.storage.pendingOutboxFrames()).single;
      final b = (await second.storage.pendingOutboxFrames()).single;
      expect(WireEnvelope.decode(a.wire).sentAtMs, 2000);
      expect(WireEnvelope.decode(b.wire).sentAtMs, 2000);
      expect(
        a.frameId,
        isNot(b.frameId),
        reason: 'dedup must not hide a competing value',
      );
      final localVersions = <int>[];
      first.messaging.onReactionSent = (_, _, _, at) => localVersions.add(at);
      await first.messaging.sendReaction(peer, 'message', '');
      expect(localVersions, [2001]);
      await first.messaging.dispose();
      final reopened = MessagingService(
        LoopbackTransport(localNodeId: id(1)),
        first.storage,
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      addTearDown(reopened.dispose);
      reopened.onReactionSent = (_, _, _, at) => localVersions.add(at);
      await reopened.sendReaction(peer, 'message', '🚀');
      expect(localVersions, [2001, 2002]);
    },
  );
}
