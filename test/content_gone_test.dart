import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// In-memory byte channel (one direction of a pipe).
class _Chan {
  final _buf = BytesBuilder(copy: false);
  int _len = 0;
  bool _closed = false;
  Completer<void>? _waiter;

  void add(Uint8List d) {
    _buf.add(d);
    _len += d.length;
    _wake();
  }

  void close() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<Uint8List> take(int maxBytes) async {
    while (_len == 0 && !_closed) {
      await (_waiter = Completer<void>()).future;
    }
    if (_len == 0 && _closed) return Uint8List(0); // EOF
    final all = _buf.takeBytes();
    _len = 0;
    if (all.length <= maxBytes) return all;
    _buf.add(Uint8List.sublistView(all, maxBytes));
    _len = all.length - maxBytes;
    return Uint8List.sublistView(all, 0, maxBytes);
  }
}

class _PipeEnd implements ReliableStream {
  _PipeEnd(this._w, this._r);
  final _Chan _w;
  final _Chan _r;
  @override
  Future<void> write(Uint8List data) async => _w.add(data);
  @override
  Future<Uint8List> read({int maxBytes = 65536}) => _r.take(maxBytes);
  @override
  Future<void> close() async => _w.close();
  @override
  Future<void> abort() async => _w.close();
}

class _StreamLink implements VeilTransport, StreamTransport {
  _StreamLink(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _StreamLink? peer;
  final _accepts = <({ReliableStream stream, NodeId src})>[];
  Completer<void>? _acceptWaiter;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    peer?._in.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(1);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();

  @override
  Future<ReliableStream?> openStream(NodeId dst) async {
    final p = peer;
    if (p == null) return null;
    final aToB = _Chan(), bToA = _Chan();
    p._accepts.add((stream: _PipeEnd(bToA, aToB), src: _me));
    final w = p._acceptWaiter;
    p._acceptWaiter = null;
    w?.complete();
    return _PipeEnd(aToB, bToA);
  }

  @override
  Future<({ReliableStream stream, NodeId src})?> acceptStream({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_accepts.isEmpty) {
      try {
        await (_acceptWaiter = Completer<void>()).future.timeout(timeout);
      } catch (_) {
        return null;
      }
    }
    return _accepts.isEmpty ? null : _accepts.removeAt(0);
  }
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

void main() {
  late NodeId a, b;
  late _StreamLink tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _StreamLink(a);
    tB = _StreamLink(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(
      tA,
      sA,
      contentPacing: Duration.zero,
      plainFileStream: true,
      streamPullMaxAttempts: 2,
    )..start();
    mB = MessagingService(
      tB,
      sB,
      contentPacing: Duration.zero,
      plainFileStream: true,
      streamPullMaxAttempts: 2,
    )..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });
  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  Future<String> offerToB(Uint8List data, String name) async {
    await mB.setFileDownloadPolicy(
      mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );
    final cid = await mA.sendFileStreaming(
      b,
      name,
      data.length,
      (o, l) async => Uint8List.sublistView(data, o, o + l),
      close: () async {},
    );
    expect(cid, isNotNull);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final msgs = await sB.loadMessages(a.hex);
      if (msgs.any((m) => m.fileContentId == cid)) return cid!;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('offer never surfaced');
  }

  Future<String> outgoingFileMessageId(String cid) async {
    for (final m in await sA.loadMessages(b.hex)) {
      if (m.direction == MessageDirection.outgoing &&
          (m.fileContentId == cid || m.fileId == cid)) {
        return m.id;
      }
    }
    fail('sender file message not found');
  }

  test(
    'sender deleted the file message: a reoffer round yields content-GONE, '
    'the receiver marks the content unavailable and stops the pending intent',
    () async {
      final data = _rnd(300000, 31);
      final cid = await offerToB(data, 'gone.bin');

      await mA.deleteMessageLocally(await outgoingFileMessageId(cid));

      // Simulate a queued intent so the terminal state must clear it.
      final failed = mB.contentDownloadFailed.first;
      await mB.downloadContentFromAny([a], cid);
      // The pull failed; now the reoffer round brings the honest answer.
      await mB.requestContentReoffer(a, cid);
      await failed.timeout(const Duration(seconds: 15));

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await mB.isContentUnavailable(cid) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await mB.isContentUnavailable(cid), isTrue);
      expect(await mB.pendingAutoResumeContentIds(), isNot(contains(cid)));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'deleting ONE of two messages sharing the same content keeps serving; '
    'deleting the last reference releases it',
    () async {
      final data = _rnd(200000, 37);
      final cid = await offerToB(data, 'shared.bin');
      // Same bytes again -> same contentId, a second message references it.
      final cid2 = await mA.sendFileStreaming(
        b,
        'shared.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      expect(cid2, cid);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final ids = [
        for (final m in await sA.loadMessages(b.hex))
          if (m.direction == MessageDirection.outgoing &&
              (m.fileContentId == cid || m.fileId == cid))
            m.id,
      ];
      expect(ids.length, 2);

      await mA.deleteMessageLocally(ids.first);
      await mB.requestContentReoffer(a, cid);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        await mB.isContentUnavailable(cid),
        isFalse,
        reason: 'another message still references the content',
      );

      await mA.deleteMessageLocally(ids.last);
      await mB.requestContentReoffer(a, cid);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await mB.isContentUnavailable(cid) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await mB.isContentUnavailable(cid), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a fresh offer clears the unavailable mark and the download completes',
    () async {
      final data = _rnd(250000, 41);
      final cid = await offerToB(data, 'revived.bin');
      await mA.deleteMessageLocally(await outgoingFileMessageId(cid));
      await mB.requestContentReoffer(a, cid);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await mB.isContentUnavailable(cid) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await mB.isContentUnavailable(cid), isTrue);

      // The sender re-sends the same bytes: same contentId, fresh offer.
      final again = await mA.sendFileStreaming(
        b,
        'revived.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      expect(again, cid);
      final cleared = DateTime.now().add(const Duration(seconds: 10));
      while (await mB.isContentUnavailable(cid) &&
          DateTime.now().isBefore(cleared)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await mB.isContentUnavailable(cid), isFalse);

      final got = mB.contentReceived.first;
      await mB.downloadContent(a, cid);
      final ev = await got.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(await sB.loadFile(cid), data);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the auto-resume loop self-heals into the terminal state: repeated '
    'failures trigger a reoffer round, the GONE reply stops the retries',
    () async {
      final data = _rnd(220000, 43);
      final cid = await offerToB(data, 'loop.bin');
      mB.downloadResumeStartDelay = const Duration(milliseconds: 200);
      mB.downloadResumeBackoffBase = const Duration(milliseconds: 200);
      mB.downloadResumeLiveGrace = const Duration(milliseconds: 300);

      await mA.deleteMessageLocally(await outgoingFileMessageId(cid));

      // One user attempt; everything after is the driver on its own.
      await mB.downloadContentFromAny([a], cid);

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!await mB.isContentUnavailable(cid) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(await mB.isContentUnavailable(cid), isTrue);
      expect(await mB.pendingAutoResumeContentIds(), isNot(contains(cid)));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
