import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/domain/message_edit.dart';
import 'package:xveil/state/messaging.dart';

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 41));

Future<HiddenVolumeStorage> _open({
  MessageDirection direction = MessageDirection.incoming,
  bool withMessage = true,
}) async {
  final kv = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  await storage.open(password: 'fixture', createIfMissing: true);
  await storage.upsertContact(Contact(nodeId: _peer));
  if (withMessage) {
    await storage.appendMessage(
      Message(
        id: 'target',
        conversationId: _peer.hex,
        direction: direction,
        body: 'original',
        timestamp: DateTime.utc(2020),
        author: _peer.hex,
        seq: 1,
        status: MessageStatus.delivered,
      ),
    );
  }
  return storage;
}

void main() {
  for (final direction in MessageDirection.values) {
    for (final reflected in [false, true]) {
      test(
        'replayed original preserves edit ($direction, reflected=$reflected)',
        () async {
          final store = await _open(direction: direction);
          try {
            await store.editMessage(
              _peer.hex,
              'target',
              'resolved edit',
              seq: 99,
              reflected: reflected,
            );
            await store.appendMessage(
              Message(
                id: 'target',
                conversationId: _peer.hex,
                direction: direction,
                body: 'original',
                timestamp: DateTime.utc(2020),
                author: _peer.hex,
                seq: 1,
                status: MessageStatus.delivered,
                positionVerified: true,
              ),
            );
            Future<void> check() async {
              final held = (await store.loadMessageById(_peer.hex, 'target'))!;
              expect(held.body, 'resolved edit');
              expect(held.edited, isTrue);
              expect(held.reflectedEdit, reflected);
              expect(held.positionVerified, isTrue);
              expect((await store.editSeqs(_peer.hex))['target'], 99);
            }

            await check();
            await store.close();
            expect(await store.open(password: 'fixture'), isTrue);
            await check();
          } finally {
            await store.close();
          }
        },
      );
    }
  }

  test(
    'reflected revisions survive reopen without becoming author events',
    () async {
      final store = await _open(direction: MessageDirection.outgoing);
      try {
        final before = await store.conversationSync(_peer.hex);
        await store.editMessage(
          _peer.hex,
          'target',
          'reflected',
          seq: 99,
          reflected: true,
        );
        expect(
          (await store.loadMessageById(_peer.hex, 'target'))!.reflectedEdit,
          isTrue,
        );
        expect((await store.editSeqs(_peer.hex))['target'], 99);
        expect(
          (await store.conversationSync(_peer.hex)).highWater,
          before.highWater,
        );
        expect(
          (await store.loadEventsSince(
            _peer.hex,
            _peer.hex,
            0,
          )).any((event) => event.body == 'reflected'),
          isFalse,
        );
        await store.close();
        expect(await store.open(password: 'fixture'), isTrue);
        expect(
          (await store.loadMessageById(_peer.hex, 'target'))!.reflectedEdit,
          isTrue,
        );
        expect((await store.editSeqs(_peer.hex))['target'], 99);
      } finally {
        await store.close();
      }
    },
  );

  test(
    'authentic same-value edit promotes once and cannot be demoted',
    () async {
      final store = await _open(direction: MessageDirection.outgoing);
      try {
        await store.editMessage(
          _peer.hex,
          'target',
          'same text',
          seq: 99,
          reflected: true,
        );
        await store.editMessage(_peer.hex, 'target', 'same text', seq: 99);
        await store.editMessage(_peer.hex, 'target', 'same text', seq: 99);
        await store.editMessage(
          _peer.hex,
          'target',
          'same text',
          seq: 99,
          reflected: true,
        );
        expect(
          (await store.loadMessageById(_peer.hex, 'target'))!.reflectedEdit,
          isFalse,
        );
        expect(
          (await store.loadEventsSince(
            _peer.hex,
            _peer.hex,
            0,
          )).where((event) => event.body == 'same text'),
          hasLength(1),
        );
        await store.close();
        expect(await store.open(password: 'fixture'), isTrue);
        expect(
          (await store.loadMessageById(_peer.hex, 'target'))!.reflectedEdit,
          isFalse,
        );
      } finally {
        await store.close();
      }
    },
  );

  test(
    'equal-revision edits converge in both arrival orders and after reopen',
    () async {
      final bodies = <String>[];
      for (final order in [
        ['left', 'right'],
        ['right', 'left'],
      ]) {
        final store = await _open();
        try {
          for (final body in order) {
            await store.editMessage(_peer.hex, 'target', body, seq: 7);
          }
          bodies.add((await store.loadMessageById(_peer.hex, 'target'))!.body);
          await store.close();
          expect(await store.open(password: 'fixture'), isTrue);
          expect(
            (await store.loadMessageById(_peer.hex, 'target'))!.body,
            bodies.last,
          );
        } finally {
          await store.close();
        }
      }
      expect(bodies.toSet(), hasLength(1));
    },
  );

  test('equal-revision same-text emoji edits converge', () async {
    final values = <String>[];
    for (final order in [
      ['AQ==', 'Ag=='],
      ['Ag==', 'AQ=='],
    ]) {
      final store = await _open();
      try {
        for (final data in order) {
          await store.editMessage(
            _peer.hex,
            'target',
            kInlineCustomEmojiFallback,
            seq: 7,
            customEmoji: [InlineCustomEmoji(offset: 0, dataB64: data)],
          );
        }
        values.add(
          (await store.loadMessageById(
            _peer.hex,
            'target',
          ))!.customEmoji.single.dataB64,
        );
      } finally {
        await store.close();
      }
    }
    expect(values.toSet(), hasLength(1));
  });

  test(
    'device journal prefers the actual higher edit revision before wall clock',
    () {
      final newer = DeviceSyncEvent(
        kind: DeviceSyncKind.msgEdit,
        key: 'target',
        tsMs: 1000,
        payload: {'peer': _peer.hex, 'body': 'new revision', 'sq': 8},
      );
      final older = DeviceSyncEvent(
        kind: DeviceSyncKind.msgEdit,
        key: 'target',
        tsMs: 2000,
        payload: {'peer': _peer.hex, 'body': 'old revision', 'sq': 7},
      );
      for (final order in [
        [newer, older],
        [older, newer],
      ]) {
        expect(
          foldDeviceSync(
            order,
          )[(DeviceSyncKind.msgEdit, 'target')]!.payload['body'],
          'new revision',
        );
      }
    },
  );

  test(
    'distinct values sharing a legacy edit frame ID are both considered',
    () async {
      final bodies = <String>[];
      for (final order in [
        ['left', 'right'],
        ['right', 'left'],
      ]) {
        final store = await _open();
        final link = LoopbackTransport();
        final service = MessagingService(link, store);
        try {
          for (final body in order) {
            await service.deliverInbound(
              InboundMessage(
                src: _peer,
                provenance: SenderProvenance.sessionPeer,
                payload: WireEnvelope.edit(
                  'target',
                  body,
                  seq: 7,
                ).withFrameId('edit:target:7').encode(),
              ),
            );
          }
          bodies.add((await store.loadMessageById(_peer.hex, 'target'))!.body);
        } finally {
          await service.dispose();
          await link.dispose();
          await store.close();
        }
      }
      expect(bodies.toSet(), hasLength(1));
    },
  );

  test('a malformed conversation cannot compact away a valid edit', () {
    final valid = DeviceSyncEvent(
      kind: DeviceSyncKind.msgEdit,
      key: 'target',
      tsMs: 1000,
      payload: {'peer': _peer.hex, 'body': 'valid', 'sq': 7},
    );
    final malformed = DeviceSyncEvent(
      kind: DeviceSyncKind.msgEdit,
      key: 'target',
      tsMs: 2000,
      payload: {'peer': 'zz-invalid-node', 'body': 'invalid', 'sq': 999},
    );
    for (final order in [
      [valid, malformed],
      [malformed, valid],
    ]) {
      expect(
        foldDeviceSync(order)[(DeviceSyncKind.msgEdit, 'target')],
        same(valid),
      );
    }
  });

  test(
    'pending edits keep their revision order when the post arrives last',
    () async {
      for (final order in [
        [7, 9],
        [9, 7],
      ]) {
        final store = await _open(withMessage: false);
        final link = LoopbackTransport();
        final service = MessagingService(link, store);
        try {
          for (final revision in order) {
            await service.deliverInbound(
              InboundMessage(
                src: _peer,
                provenance: SenderProvenance.sessionPeer,
                payload: WireEnvelope.edit(
                  'target',
                  'version-$revision',
                  seq: revision,
                ).withFrameId('pending-$revision').encode(),
              ),
            );
          }
          await service.deliverInbound(
            InboundMessage(
              src: _peer,
              provenance: SenderProvenance.sessionPeer,
              payload: WireEnvelope.message(
                'original',
                id: 'target',
                seq: 1,
                sentAtMs: 1000,
              ).encode(),
            ),
          );
          final held = (await store.loadMessageById(_peer.hex, 'target'))!;
          expect(held.body, 'version-9');
          expect(held.edited, isTrue);
          expect((await store.editSeqs(_peer.hex))['target'], 9);
        } finally {
          await service.dispose();
          await link.dispose();
          await store.close();
        }
      }
    },
  );

  test(
    'same-text mirrored edits advance their revision and emoji together',
    () async {
      final store = await _open();
      final link = LoopbackTransport();
      final service = MessagingService(link, store);
      try {
        await service.applyMirroredEdit(
          peer: _peer,
          msgId: 'target',
          body: kInlineCustomEmojiFallback,
          seq: 7,
          customEmoji: const [InlineCustomEmoji(offset: 0, dataB64: 'AQ==')],
        );
        await service.applyMirroredEdit(
          peer: _peer,
          msgId: 'target',
          body: kInlineCustomEmojiFallback,
          seq: 9,
          customEmoji: const [InlineCustomEmoji(offset: 0, dataB64: 'Ag==')],
        );
        expect((await store.editSeqs(_peer.hex))['target'], 9);
        expect(
          (await store.loadMessageById(
            _peer.hex,
            'target',
          ))!.customEmoji.single.dataB64,
          'Ag==',
        );
      } finally {
        await service.dispose();
        await link.dispose();
        await store.close();
      }
    },
  );

  test(
    'storage and device journal agree on all orders of clock-skewed ties',
    () async {
      final values = ['alpha', 'beta', 'gamma'];
      final expected = values.reduce(
        (a, b) =>
            messageEditContentHash(
                  a,
                  const [],
                ).compareTo(messageEditContentHash(b, const [])) >
                0
            ? a
            : b,
      );
      final orders = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ];
      for (final order in orders) {
        final store = await _open();
        try {
          final events = <DeviceSyncEvent>[];
          for (final i in order) {
            await store.editMessage(_peer.hex, 'target', values[i], seq: 7);
            events.add(
              DeviceSyncEvent(
                kind: DeviceSyncKind.msgEdit,
                key: 'target',
                tsMs: 3000 - i * 1000,
                payload: {'peer': _peer.hex, 'body': values[i], 'sq': 7},
              ),
            );
          }
          expect(
            (await store.loadMessageById(_peer.hex, 'target'))!.body,
            expected,
          );
          expect(
            foldDeviceSync(
              events,
            )[(DeviceSyncKind.msgEdit, 'target')]!.payload['body'],
            expected,
          );
          final count = (await store.loadMessageHistory(
            _peer.hex,
            'target',
          )).length;
          for (final value in values) {
            await store.editMessage(_peer.hex, 'target', value, seq: 7);
          }
          expect(
            (await store.loadMessageHistory(_peer.hex, 'target')).length,
            count,
          );
        } finally {
          await store.close();
        }
      }
    },
  );

  test(
    'locally queued simultaneous edits have different durable IDs',
    () async {
      final frameIds = <String>[];
      for (final body in ['left', 'right']) {
        final store = await _open(direction: MessageDirection.outgoing);
        final link = LoopbackTransport();
        final service = MessagingService(link, store);
        try {
          await service.editOwnMessage('target', body);
          frameIds.add((await store.pendingOutboxFrames()).single.frameId);
        } finally {
          await service.dispose();
          await link.dispose();
          await store.close();
        }
      }
      expect(frameIds.toSet(), hasLength(2));
    },
  );
}
