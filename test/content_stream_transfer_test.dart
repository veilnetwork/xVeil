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
import 'package:xveil/domain/content_manifest.dart';
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
}

/// Test fault: after [passBytes] bytes written by this endpoint, the write side
/// turns into a blackhole. Writes still resolve (like a lower layer accepting
/// cells into a dead path), but the peer receives no more bytes and no EOF.
class _BlackholeWriteStream implements ReliableStream {
  _BlackholeWriteStream(this._inner, {required this.passBytes});

  final ReliableStream _inner;
  final int passBytes;
  int _written = 0;
  bool _blackholed = false;

  @override
  Future<void> write(Uint8List data) async {
    if (_blackholed) return;
    final remaining = passBytes - _written;
    if (remaining <= 0) {
      _blackholed = true;
      return;
    }
    if (data.length <= remaining) {
      _written += data.length;
      await _inner.write(data);
      return;
    }
    await _inner.write(Uint8List.sublistView(data, 0, remaining));
    _written += remaining;
    _blackholed = true;
  }

  @override
  Future<Uint8List> read({int maxBytes = 65536}) =>
      _inner.read(maxBytes: maxBytes);

  @override
  Future<void> close() async {
    if (_blackholed) return;
    await _inner.close();
  }
}

class _CloseOnWriteStream implements ReliableStream {
  _CloseOnWriteStream(this._inner);

  final ReliableStream _inner;
  bool _closed = false;

  @override
  Future<void> write(Uint8List data) async {
    if (_closed) return;
    _closed = true;
    await _inner.close();
  }

  @override
  Future<Uint8List> read({int maxBytes = 65536}) =>
      _inner.read(maxBytes: maxBytes);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inner.close();
  }
}

class _GateWriteStream implements ReliableStream {
  _GateWriteStream(
    this._inner, {
    required this.chunkBytes,
    required this.onBlocked,
  });

  final ReliableStream _inner;
  final int chunkBytes;
  final void Function(_GateWriteStream stream) onBlocked;
  final Completer<void> _release = Completer<void>();
  bool _blocked = false;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> write(Uint8List data) async {
    var off = 0;
    while (off < data.length) {
      final end = min(off + chunkBytes, data.length);
      await _inner.write(Uint8List.sublistView(data, off, end));
      if (!_blocked) {
        _blocked = true;
        onBlocked(this);
        await _release.future;
      }
      off = end;
    }
  }

  @override
  Future<Uint8List> read({int maxBytes = 65536}) =>
      _inner.read(maxBytes: maxBytes);

  @override
  Future<void> close() => _inner.close();
}

/// Datagram + reliable-stream loopback link between two peers.
class _StreamLink implements VeilTransport, StreamTransport {
  _StreamLink(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _StreamLink? peer;
  final routes = <String, _StreamLink>{};
  final _accepts = <({ReliableStream stream, NodeId src})>[];
  final acceptStreamWrappers =
      <ReliableStream Function(ReliableStream stream)>[];
  int openStreamFailures = 0;
  int openStreamAttemptCount = 0;
  int openedStreamCount = 0;
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
  }) async => (routes[dst.hex] ?? peer)?._in.add(
    InboundMessage(src: _me, payload: payload),
  );
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
    openStreamAttemptCount++;
    if (openStreamFailures > 0) {
      openStreamFailures--;
      return null;
    }
    final p = routes[dst.hex] ?? peer;
    if (p == null) return null;
    openedStreamCount++;
    final aToB = _Chan(), bToA = _Chan();
    ReliableStream peerStream = _PipeEnd(bToA, aToB);
    if (p.acceptStreamWrappers.isNotEmpty) {
      peerStream = p.acceptStreamWrappers.removeAt(0)(peerStream);
    }
    // Peer accepts the B-end; I keep the A-end.
    p._accepts.add((stream: peerStream, src: _me));
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
    mA = MessagingService(tA, sA, contentPacing: Duration.zero)..start();
    mB = MessagingService(tB, sB, contentPacing: Duration.zero)..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });
  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  test(
    'STREAM download: receiver pulls a multi-piece file over a reliable '
    'stream, verifies every piece, stores it (no datagram chunk/re-request)',
    () async {
      final data = _rnd(500000, 7); // ~2 pieces
      final cid = ContentManifest.fromBytes('movie.bin', data).contentId;
      // A advertises + serves-from-source; B is "always ask" so it stays an OFFER.
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      await mA.sendFileStreaming(
        b,
        'movie.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final got = mB.contentReceived.first;
      final r = await mB.downloadContent(a, cid);
      expect(r, ContentDownloadResult.started);
      final ev = await got.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(
        await sB.loadFile(cid),
        data,
        reason: 'pulled + verified the whole',
      );
      expect(
        tB.openedStreamCount,
        greaterThanOrEqualTo(2),
        reason:
            'multi-piece stream downloads should pull piece ranges in parallel',
      );
    },
  );

  test(
    'STREAM range pull fills a slow per-stream channel in parallel',
    () async {
      final data = _rnd(720000, 37); // 3 pieces at the default 256 KiB.
      final cid = ContentManifest.fromBytes('slow-range.bin', data).contentId;
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      await mA.sendFileStreaming(
        b,
        'slow-range.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final gated = <_GateWriteStream>[];
      final allBlocked = Completer<void>();
      for (var i = 0; i < 3; i++) {
        tA.acceptStreamWrappers.add(
          (stream) => _GateWriteStream(
            stream,
            chunkBytes: 16 * 1024,
            onBlocked: (gate) {
              gated.add(gate);
              if (gated.length >= 3 && !allBlocked.isCompleted) {
                allBlocked.complete();
              }
            },
          ),
        );
      }

      final got = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await allBlocked.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException(
          'range pull did not start three gated streams in parallel',
        ),
      );
      expect(
        tB.openedStreamCount,
        greaterThanOrEqualTo(3),
        reason:
            'piece-range workers should all open before any gated stream drains',
      );
      for (final gate in gated) {
        gate.release();
      }
      await got.timeout(const Duration(seconds: 20));

      expect(await sB.loadFile(cid), data);
    },
  );

  test(
    'STREAM range pull resumes from already stored verified pieces',
    () async {
      final data = _rnd(700000, 41); // 3 pieces at the default 256 KiB.
      final manifest = ContentManifest.fromBytes('partial-range.bin', data);
      final cid = manifest.contentId;
      await sB.storeFilePiece(
        cid,
        0,
        manifest.pieceCount,
        manifest.pieceSize,
        manifest.size,
        Uint8List.sublistView(data, 0, manifest.pieceLength(0)),
        name: manifest.name,
      );
      expect(await sB.hasFile(cid), isFalse, reason: 'only piece 0 is present');

      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      final serveOffsets = <int>[];
      await mA.sendFileStreaming(b, 'partial-range.bin', data.length, (
        o,
        l,
      ) async {
        serveOffsets.add(o);
        return Uint8List.sublistView(data, o, o + l);
      }, close: () async {});
      serveOffsets.clear(); // ignore manifest hashing reads.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final got = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await got.timeout(const Duration(seconds: 20));

      expect(await sB.loadFile(cid), data);
      expect(
        serveOffsets,
        isNot(contains(0)),
        reason:
            'verified piece 0 was already stored and must not be re-fetched',
      );
      expect(
        serveOffsets,
        contains(ContentManifest.defaultPieceSize),
        reason: 'the first missing piece should be fetched by range offset',
      );
    },
  );

  test('STREAM range pull survives a transient stream-open outage', () async {
    final data = _rnd(700000, 53); // 3 pieces at the default 256 KiB.
    final cid = ContentManifest.fromBytes('range-outage.bin', data).contentId;
    await mB.setFileDownloadPolicy(
      mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );
    await mA.sendFileStreaming(
      b,
      'range-outage.bin',
      data.length,
      (o, l) async => Uint8List.sublistView(data, o, o + l),
      close: () async {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Three workers × three failed open waves. The old range-pull budget
    // (3 attempts/piece for one source) gave up here; a Wi-Fi→mobile handoff can
    // easily look like this before fresh circuits/streams become available.
    tB.openStreamFailures = 9;

    final got = mB.contentReceived.firstWhere((e) => e.contentId == cid);
    expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
    await got.timeout(const Duration(seconds: 20));

    expect(await sB.loadFile(cid), data);
    expect(
      tB.openStreamAttemptCount,
      greaterThanOrEqualTo(12),
      reason:
          'range workers should keep retrying after the first three failed waves',
    );
  });

  test(
    'STREAM range pull opens enough parallel piece streams for large files',
    () async {
      await mA.dispose();
      await mB.dispose();
      mA = MessagingService(
        tA,
        sA,
        contentPacing: Duration.zero,
        streamRangeParallelism: 6,
      )..start();
      mB = MessagingService(
        tB,
        sB,
        contentPacing: Duration.zero,
        streamRangeParallelism: 6,
      )..start();

      final size = ContentManifest.defaultPieceSize * 6 + 1;
      final data = _rnd(size, 71);
      final cid = ContentManifest.fromBytes('parallel.bin', data).contentId;
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      await mA.sendFileStreaming(
        b,
        'parallel.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final got = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await got.timeout(const Duration(seconds: 20));
      expect(await sB.loadFile(cid), data);
      expect(
        tB.openedStreamCount,
        greaterThanOrEqualTo(6),
        reason:
            'large range downloads should fan out beyond the old 3-stream cap',
      );
    },
  );

  test(
    'STREAM swarm: a downloaded blob can be served to another accepted peer',
    () async {
      final data = _rnd(520000, 17); // multi-piece
      final cid = ContentManifest.fromBytes('swarm.bin', data).contentId;
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );

      // A offers and serves from its original source; B downloads into its app
      // storage. This is the "first leecher completes" phase.
      await mA.sendFileStreaming(
        b,
        'swarm.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final gotB = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await gotB.timeout(const Duration(seconds: 20));
      expect(await sB.loadFile(cid), data);

      // Now C has only B as its source. B no longer has A's original file handle;
      // it must seed the verified stored blob via readFileRange.
      final c = _id(3);
      final tC = _StreamLink(c);
      final sC = HiddenVolumeStorage(_mem());
      await sC.open(password: 'c', createIfMissing: true);
      final mC = MessagingService(tC, sC, contentPacing: Duration.zero)
        ..start();
      addTearDown(() async {
        await mC.dispose();
        await sC.close();
      });
      await sB.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await sC.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      tB.peer = tC;
      tC.peer = tB;

      final gotC = mC.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mC.downloadContent(b, cid), ContentDownloadResult.started);
      final ev = await gotC.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(await sC.loadFile(cid), data);
    },
  );

  test(
    'STREAM swarm download falls through to the next accepted source',
    () async {
      final data = _rnd(540000, 23);
      final cid = ContentManifest.fromBytes('multi-source.bin', data).contentId;
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );

      // A seeds B first; B becomes a verified holder.
      await mA.sendFileStreaming(
        b,
        'multi-source.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final gotB = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await gotB.timeout(const Duration(seconds: 20));
      expect(await sB.loadFile(cid), data);

      final c = _id(3);
      final d = _id(4);
      final e = _id(5);
      final tC = _StreamLink(c);
      final tD = _StreamLink(d);
      final tE = _StreamLink(e);
      final sC = HiddenVolumeStorage(_mem());
      final sD = HiddenVolumeStorage(_mem());
      final sE = HiddenVolumeStorage(_mem());
      await sC.open(password: 'c', createIfMissing: true);
      await sD.open(password: 'd', createIfMissing: true);
      await sE.open(password: 'e', createIfMissing: true);
      final mC = MessagingService(
        tC,
        sC,
        contentPacing: Duration.zero,
        streamPullMaxAttempts: 2,
      )..start();
      final mD = MessagingService(tD, sD, contentPacing: Duration.zero)
        ..start();
      final mE = MessagingService(tE, sE, contentPacing: Duration.zero)
        ..start();
      addTearDown(() async {
        await mC.dispose();
        await mD.dispose();
        await mE.dispose();
        await sC.close();
        await sD.close();
        await sE.close();
      });

      await sC.upsertContact(
        Contact(nodeId: d, status: ContactStatus.accepted),
      );
      await sD.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await sC.upsertContact(
        Contact(nodeId: e, status: ContactStatus.accepted),
      );
      await sE.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await sC.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await mC.setFileDownloadPolicy(
        mC.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      tC.routes[d.hex] = tD;
      tC.routes[e.hex] = tE;
      tC.routes[b.hex] = tB;
      tB.routes[c.hex] = tC;
      tD.routes[c.hex] = tC;
      tE.routes[c.hex] = tC;

      await mD.sendFileStreaming(
        c,
        'multi-source.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await mE.sendFileStreaming(
        c,
        'multi-source.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await mB.sendFileStreaming(c, 'multi-source.bin', data.length, (
        o,
        l,
      ) async {
        final bytes = await sB.readFileRange(cid, o, l);
        if (bytes == null) throw StateError('stored blob missing');
        return bytes;
      }, close: () async {});
      await Future<void>.delayed(const Duration(milliseconds: 80));

      tD.acceptStreamWrappers.add((stream) => _CloseOnWriteStream(stream));
      tE.acceptStreamWrappers.add((stream) => _CloseOnWriteStream(stream));
      final gotC = mC.contentReceived.firstWhere((e) => e.contentId == cid);
      final result = await mC.downloadContent(d, cid);
      expect(result, ContentDownloadResult.started);
      final ev = await gotC.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(await sC.loadFile(cid), data);
      expect(
        tC.openedStreamCount,
        greaterThanOrEqualTo(3),
        reason: 'C should try every known holder, not stop at retry budget 2',
      );
    },
  );

  test(
    'STREAM swarm resume switches to another holder after partial payload',
    () async {
      final data = _rnd(700000, 31); // 3 pieces at the default 256 KiB.
      final cid = ContentManifest.fromBytes('cross-source.bin', data).contentId;
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );

      // A fully seeds B first, so B can later act as an independent holder.
      await mA.sendFileStreaming(
        b,
        'cross-source.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final gotB = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mB.downloadContent(a, cid), ContentDownloadResult.started);
      await gotB.timeout(const Duration(seconds: 20));
      expect(await sB.loadFile(cid), data);

      final c = _id(3);
      final tC = _StreamLink(c);
      final sC = HiddenVolumeStorage(_mem());
      await sC.open(password: 'c', createIfMissing: true);
      MessagingService newReceiver() => MessagingService(
        tC,
        sC,
        contentPacing: Duration.zero,
        streamPayloadIdleTimeout: const Duration(milliseconds: 120),
        streamPullMaxAttempts: 2,
      )..start();
      var mC = newReceiver();
      addTearDown(() async {
        await mC.dispose();
        await sC.close();
      });

      await sA.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: c, status: ContactStatus.accepted),
      );
      await sC.upsertContact(
        Contact(nodeId: a, status: ContactStatus.accepted),
      );
      await sC.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await mC.setFileDownloadPolicy(
        mC.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      tC.routes[a.hex] = tA;
      tC.routes[b.hex] = tB;
      tA.routes[c.hex] = tC;
      tB.routes[c.hex] = tC;

      // C learns two holders for the same contentId, in order: A then B.
      await mA.sendFileStreaming(
        c,
        'cross-source.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      final bServeOffsets = <int>[];
      await mB.sendFileStreaming(c, 'cross-source.bin', data.length, (
        o,
        l,
      ) async {
        bServeOffsets.add(o);
        final bytes = await sB.readFileRange(cid, o, l);
        if (bytes == null) throw StateError('stored blob missing');
        return bytes;
      }, close: () async {});
      bServeOffsets.clear(); // ignore manifest hashing reads.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Simulate an app/service restart after receiving the offers: the
      // in-memory _offered source set is gone, so C must rediscover candidate
      // holders from persisted incoming file-offer messages.
      await mC.dispose();
      mC = newReceiver();
      await mC.setFileDownloadPolicy(
        mC.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );

      // A's first stream sends enough for C to verify piece 0, then blackholes.
      // C must retry B with a resume offset instead of restarting at byte 0.
      tA.acceptStreamWrappers.add(
        (stream) => _BlackholeWriteStream(stream, passBytes: 350 * 1024),
      );

      final gotC = mC.contentReceived.firstWhere((e) => e.contentId == cid);
      expect(await mC.downloadContent(a, cid), ContentDownloadResult.started);
      final ev = await gotC.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(await sC.loadFile(cid), data);
      expect(tC.openedStreamCount, greaterThanOrEqualTo(2));
      expect(
        bServeOffsets,
        isNotEmpty,
        reason: 'the second holder should have served the resumed tail',
      );
      expect(
        bServeOffsets.first,
        ContentManifest.defaultPieceSize,
        reason:
            'cross-source retry should resume after the verified first piece',
      );
    },
  );

  test('STREAM download to an UNENCRYPTED file writes the plaintext + nothing '
      'in the app', () async {
    final data = _rnd(400000, 9);
    final cid = ContentManifest.fromBytes('clip.bin', data).contentId;
    await mB.setFileDownloadPolicy(
      mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );
    await mA.sendFileStreaming(
      b,
      'clip.bin',
      data.length,
      (o, l) async => Uint8List.sublistView(data, o, o + l),
      close: () async {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final dir = await Directory.systemTemp.createTemp('xveil-stream');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final dest = '${dir.path}/clip.bin';
    final raf = await File(dest).open(mode: FileMode.write);
    final got = mB.contentReceived.first;
    final r = await mB.downloadContentToFile(
      a,
      cid,
      dest,
      write: (offset, bytes) async {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      },
      close: () async {
        await raf.close();
      },
    );
    expect(r, ContentDownloadResult.started);
    final ev = await got.timeout(const Duration(seconds: 20));
    expect(ev.savedToPath, dest);
    expect(await File(dest).readAsBytes(), data);
    expect(
      await sB.hasFile(cid),
      isFalse,
      reason: 'plaintext-to-file keeps nothing',
    );
  });

  test('STREAM download resumes on a fresh stream after payload idle', () async {
    await mA.dispose();
    await mB.dispose();
    mA = MessagingService(
      tA,
      sA,
      contentPacing: Duration.zero,
      streamPayloadIdleTimeout: const Duration(milliseconds: 120),
      streamPullMaxAttempts: 4,
    )..start();
    mB = MessagingService(
      tB,
      sB,
      contentPacing: Duration.zero,
      streamPayloadIdleTimeout: const Duration(milliseconds: 120),
      streamPullMaxAttempts: 4,
    )..start();

    // The sender's first accepted stream blackholes after enough bytes for the
    // receiver to verify one 256 KiB piece, but before the full file arrives.
    tA.acceptStreamWrappers.add(
      (stream) => _BlackholeWriteStream(stream, passBytes: 350 * 1024),
    );

    final data = _rnd(700000, 13); // 3 pieces
    final cid = ContentManifest.fromBytes('resume.bin', data).contentId;
    await mB.setFileDownloadPolicy(
      mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
    );
    await mA.sendFileStreaming(
      b,
      'resume.bin',
      data.length,
      (o, l) async => Uint8List.sublistView(data, o, o + l),
      close: () async {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Drop the in-memory offer before downloading so this test keeps exercising
    // the legacy sequential stream resume path rather than the newer parallel
    // range-pull path, which needs a live manifest handle.
    await mB.dispose();
    mB = MessagingService(
      tB,
      sB,
      contentPacing: Duration.zero,
      streamPayloadIdleTimeout: const Duration(milliseconds: 120),
      streamPullMaxAttempts: 4,
    )..start();

    final got = mB.contentReceived.first;
    final r = await mB.downloadContent(a, cid);
    expect(r, ContentDownloadResult.started);
    final ev = await got.timeout(const Duration(seconds: 8));
    expect(ev.contentId, cid);
    expect(
      tB.openedStreamCount,
      greaterThanOrEqualTo(2),
      reason: 'receiver should abandon the blackholed stream and retry',
    );
    expect(
      await sB.loadFile(cid),
      data,
      reason: 'resume stream must reconstruct the original bytes intact',
    );
  });
}
