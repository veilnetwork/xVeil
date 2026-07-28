import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// Transport that drops every send and lets a test FEED inbound frames — so we
/// can drive the serve/fetch caches without a peer.
class _Feed implements VeilTransport {
  _Feed(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  void feed(NodeId from, Uint8List payload) =>
      _in.add(InboundMessage(src: from, payload: payload));
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  final me = _id(1);
  final peer = _id(2);

  test(
    'serving cache evicts files idle past the TTL — the sender no longer '
    'keeps the full bytes of every file it ever sent (RAM bounded)',
    () async {
      var clock = DateTime(2026, 6, 28, 12, 0, 0);
      final s = HiddenVolumeStorage(_mem());
      await s.open(password: 'a', createIfMissing: true);
      await s.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final m = MessagingService(
        _Feed(me),
        s,
        now: () => clock,
        contentPacing: Duration.zero,
      )..start();
      addTearDown(m.dispose);

      await m.sendContent(peer, _rnd(2000, 1), 'f1.bin');
      await m.sendContent(peer, _rnd(2000, 2), 'f2.bin');
      expect(m.servingCount, 2, reason: 'both freshly advertised');

      clock = clock.add(
        const Duration(minutes: 11),
      ); // past _servingTtl (10 min)
      await m.sendContent(
        peer,
        _rnd(2000, 3),
        'f3.bin',
      ); // advertise → _evictServing
      expect(
        m.servingCount,
        1,
        reason: 'f1+f2 idle past the TTL are evicted; only f3 remains',
      );
    },
  );

  test('the serving cache is bounded even when nothing has aged out', () async {
    // The TTL only reclaims IDLE entries. A sender that keeps offering stays
    // inside the window, so the count cap is the only thing bounding this map
    // — and every entry can hold an open source. Without it the sender grows
    // for as long as it keeps sending.
    var clock = DateTime(2026, 6, 28, 12, 0, 0);
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'a', createIfMissing: true);
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final m = MessagingService(
      _Feed(me),
      s,
      now: () => clock,
      contentPacing: Duration.zero,
    )..start();
    addTearDown(m.dispose);

    // Well past the cap of 256, all within one TTL window so nothing ages out.
    for (var i = 0; i < 300; i++) {
      await m.sendContent(peer, _rnd(64, i), 'f$i.bin');
    }
    expect(
      m.servingCount,
      lessThanOrEqualTo(256),
      reason: 'the count cap must bound the map when the TTL cannot',
    );
    // And it must still be serving the recent ones rather than having emptied
    // itself, which would satisfy the bound for the wrong reason.
    expect(m.servingCount, greaterThan(1));
  });

  test('abandoned fetch reassembler is evicted when a later transfer starts '
      '(no leaked partial-file buffers)', () async {
    var clock = DateTime(2026, 6, 28, 12, 0, 0);
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'b', createIfMissing: true);
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final t = _Feed(me);
    final m = MessagingService(
      t,
      s,
      now: () => clock,
      contentPacing: Duration.zero,
    )..start();
    addTearDown(m.dispose);

    // The peer advertises a file → we start fetching it; NO chunks ever follow.
    final man1 = ContentManifest.fromBytes('a.bin', _rnd(3000, 7));
    t.feed(peer, contentManifestEnvelope(jsonEncode(man1.toJson())).encode());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(m.fetchingCount, 1, reason: 'started fetching a.bin');

    // Past the stale timeout a NEW transfer starts → the abandoned one is evicted.
    clock = clock.add(const Duration(minutes: 6)); // past stale timeout (5 min)
    final man2 = ContentManifest.fromBytes('b.bin', _rnd(3000, 8));
    t.feed(peer, contentManifestEnvelope(jsonEncode(man2.toJson())).encode());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      m.fetchingCount,
      1,
      reason: 'the abandoned a.bin reassembler is evicted; only b.bin remains',
    );
  });

  test('same-content retry closes a stale plaintext sink and dispose closes '
      'the replacement', () async {
    var clock = DateTime(2026, 6, 28, 12, 0, 0);
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'c', createIfMissing: true);
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final t = _Feed(me);
    final m = MessagingService(
      t,
      s,
      now: () => clock,
      contentPacing: Duration.zero,
    )..start();
    addTearDown(m.dispose);
    await m.setFileDownloadPolicy(
      m.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );

    final manifest = ContentManifest.fromBytes('plain.bin', _rnd(3000, 9));
    t.feed(
      peer,
      contentManifestEnvelope(jsonEncode(manifest.toJson())).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    var staleClosed = 0;
    var replacementClosed = 0;
    await m.downloadContentToFile(
      peer,
      manifest.contentId,
      '/tmp/stale.bin',
      write: (_, _) async {},
      close: () async => staleClosed++,
    );
    expect(m.fetchingCount, 1);

    clock = clock.add(const Duration(minutes: 6));
    await m.downloadContentToFile(
      peer,
      manifest.contentId,
      '/tmp/replacement.bin',
      write: (_, _) async {},
      close: () async => replacementClosed++,
    );
    expect(
      staleClosed,
      1,
      reason: 'same-content retry must evict and close the abandoned sink',
    );
    expect(
      replacementClosed,
      0,
      reason: 'the replacement fetch remains active',
    );
    expect(
      m.fetchingCount,
      1,
      reason: 'the same content id restarted instead of staying parked',
    );

    await m.dispose();
    expect(
      replacementClosed,
      1,
      reason: 'dispose must close every active plaintext fetch sink',
    );
  });

  test(
    'full manifests and compact refs share one 256-offer RAM budget',
    () async {
      final s = HiddenVolumeStorage(_mem());
      await s.open(password: 'd', createIfMissing: true);
      await s.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final t = _Feed(me);
      final m = MessagingService(t, s, contentPacing: Duration.zero)..start();
      addTearDown(m.dispose);
      await m.setFileDownloadPolicy(
        m.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );

      for (var i = 0; i < 130; i++) {
        final manifest = ContentManifest.fromBytes(
          'full-$i.bin',
          Uint8List.fromList([i]),
        );
        t.feed(
          peer,
          contentManifestEnvelope(jsonEncode(manifest.toJson())).encode(),
        );
        final refId = (1000 + i).toRadixString(16).padLeft(64, '0');
        t.feed(
          peer,
          contentManifestEnvelope(
            jsonEncode({
              'ref': 1,
              'id': refId,
              'name': 'ref-$i.bin',
              'size': 1,
            }),
          ).encode(),
        );
      }

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (m.offeredContentCount < 256 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        m.offeredContentCount,
        256,
        reason: 'alternating manifests and refs must not get separate 256 caps',
      );
      await m.dispose();
      expect(
        m.offeredContentCount,
        0,
        reason: 'dispose must release manifest hash lists immediately',
      );
    },
  );

  test('replacing a parked plaintext save closes the old sink and dispose '
      'awaits the replacement', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'e', createIfMissing: true);
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final m = MessagingService(_Feed(me), s, contentPacing: Duration.zero)
      ..start();
    addTearDown(m.dispose);
    final cid = List.filled(32, 'ab').join();
    var firstClosed = 0;
    var secondClosed = 0;

    expect(
      await m.downloadContentToFile(
        peer,
        cid,
        '/tmp/first-parked.bin',
        write: (_, _) async {},
        close: () async => firstClosed++,
      ),
      ContentDownloadResult.requestedReoffer,
    );
    expect(
      await m.downloadContentToFile(
        peer,
        cid,
        '/tmp/second-parked.bin',
        write: (_, _) async {},
        close: () async => secondClosed++,
      ),
      ContentDownloadResult.requestedReoffer,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      firstClosed,
      1,
      reason: 'replacing a parked destination must not leak its file handle',
    );
    expect(secondClosed, 0);

    await m.dispose();
    expect(
      secondClosed,
      1,
      reason: 'dispose must await the currently parked destination close',
    );
  });
}
