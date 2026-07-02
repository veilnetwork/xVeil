import 'dart:async';
import 'dart:io';
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

/// In-memory byte channel (one direction of a pipe): writes append, reads drain
/// (await on empty), EOF when the writer closes.
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
    _buf.add(Uint8List.sublistView(all, maxBytes)); // carry the remainder
    _len = all.length - maxBytes;
    return Uint8List.sublistView(all, 0, maxBytes);
  }
}

class _PipeEnd implements ReliableStream {
  _PipeEnd(this._w, this._r);
  final _Chan _w; // I write here (peer reads)
  final _Chan _r; // I read here
  @override
  Future<void> write(Uint8List data) async => _w.add(data);
  @override
  Future<Uint8List> read({int maxBytes = 65536}) => _r.take(maxBytes);
  @override
  Future<void> close() async => _w.close();
  @override
  Future<void> abort() async => _w.close();
}

/// Datagram + reliable-stream loopback link between two peers. Setting [peer]
/// to null models a dead network (datagrams vanish, stream opens fail) — the
/// "interrupted download" condition the auto-resume driver must recover from.
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
        return null; // timed out
      }
    }
    return _accepts.isEmpty ? null : _accepts.removeAt(0);
  }
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

MessagingService _makeService(_StreamLink t, HiddenVolumeStorage s) =>
    MessagingService(
      t,
      s,
      contentPacing: Duration.zero,
      plainFileStream: true,
      streamPullMaxAttempts: 2,
    );

void _shrinkResumeDelays(MessagingService m) {
  m.downloadResumeStartDelay = const Duration(milliseconds: 200);
  m.downloadResumeBackoffBase = const Duration(milliseconds: 200);
  m.downloadResumeLiveGrace = const Duration(milliseconds: 500);
}

Future<void> _waitOffer(HiddenVolumeStorage s, NodeId from, String cid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    for (final m in await s.loadMessages(from.hex)) {
      if (m.fileContentId == cid) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('offer for $cid never surfaced');
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
    mA = _makeService(tA, sA)..start();
    mB = _makeService(tB, sB)..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });
  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  /// A advertises [data]; B (policy "always ask") ends up with a stored offer.
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
    await _waitOffer(sB, a, cid!);
    return cid;
  }

  void cutLink() {
    tA.peer = null;
    tB.peer = null;
  }

  void healLink() {
    tA.peer = tB;
    tB.peer = tA;
  }

  test(
    'encrypted download interrupted by shutdown auto-resumes on the next '
    'service start (durable pending registry)',
    () async {
      final data = _rnd(500000, 11);
      final cid = await offerToB(data, 'movie.bin');

      // Network dies, the user taps download anyway: the attempt cannot
      // complete, but the durable intent must be recorded.
      cutLink();
      await mB.downloadContent(a, cid);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await mB.pendingAutoResumeContentIds(), contains(cid));

      // App shutdown mid-intent.
      await mB.dispose();

      // Relaunch on the same storage with the network back: no user action.
      healLink();
      final mB2 = _makeService(tB, sB);
      _shrinkResumeDelays(mB2);
      final got = mB2.contentReceived.first;
      mB2.start();
      try {
        final ev = await got.timeout(const Duration(seconds: 20));
        expect(ev.contentId, cid);
        expect(await sB.loadFile(cid), data);
        // The registry record is consumed by the completion.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(await mB2.pendingAutoResumeContentIds(), isNot(contains(cid)));
      } finally {
        await mB2.dispose();
        mB = _makeService(tB, sB); // give tearDown something to dispose
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'failed swarm download retries with backoff in-session and completes '
    'once the network heals',
    () async {
      final data = _rnd(300000, 13);
      final cid = await offerToB(data, 'doc.bin');
      _shrinkResumeDelays(mB);

      cutLink();
      final got = mB.contentReceived.first;
      final r = await mB.downloadContentFromAny([a], cid);
      expect(r, ContentDownloadResult.noOffer);

      healLink();
      final ev = await got.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(await sB.loadFile(cid), data);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'plain-file download interrupted by shutdown re-drives to the SAME '
    'destination path across a service restart',
    () async {
      final data = _rnd(400000, 17);
      final cid = await offerToB(data, 'save.bin');
      final dir = await Directory.systemTemp.createTemp('xveil-resume-test');
      final path = '${dir.path}/save.bin';
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      cutLink();
      final raf = await File(path).open(mode: FileMode.write);
      var closed = false;
      await mB.downloadContentToFile(
        a,
        cid,
        path,
        write: (o, bytes) async {
          await raf.setPosition(o);
          await raf.writeFrom(bytes);
        },
        close: () async {
          if (closed) return;
          closed = true;
          await raf.close();
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await mB.pendingAutoResumeContentIds(), contains(cid));
      await mB.dispose();
      if (!closed) {
        closed = true;
        await raf.close();
      }

      healLink();
      final mB2 = _makeService(tB, sB);
      _shrinkResumeDelays(mB2);
      final got = mB2.contentReceived.firstWhere((e) => e.contentId == cid);
      mB2.start();
      try {
        final ev = await got.timeout(const Duration(seconds: 20));
        expect(ev.savedToPath, path);
        expect(await File(path).readAsBytes(), data);
      } finally {
        await mB2.dispose();
        mB = _makeService(tB, sB);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
