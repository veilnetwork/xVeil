import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/serve_source.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

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
    if (_len == 0 && _closed) return Uint8List(0);
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
  final _accepts = <({ReliableStream stream, NodeId src, SenderProvenance provenance})>[];
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
  Future<void> warmStreamPeer(NodeId dst) async {}

  @override
  Future<ReliableStream?> openStream(NodeId dst) async {
    final p = peer;
    if (p == null) return null;
    final aToB = _Chan(), bToA = _Chan();
    p._accepts.add((
      stream: _PipeEnd(bToA, aToB),
      src: _me,
      // The anonymous lane is claimed BY CONSTRUCTION in production (the
      // initiator comes off an onion cell), so the fake says exactly that.
      provenance: SenderProvenance.claimed,
    ));
    final w = p._acceptWaiter;
    p._acceptWaiter = null;
    w?.complete();
    return _PipeEnd(aToB, bToA);
  }

  @override
  Future<({ReliableStream stream, NodeId src, SenderProvenance provenance})?>
  acceptStream({
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
      streamPullMaxAttempts: 3,
    )..start();
    mB = MessagingService(
      tB,
      sB,
      contentPacing: Duration.zero,
      plainFileStream: true,
      streamPullMaxAttempts: 3,
    )..start();
    // The production provider wires this; the raw test constructor doesn't.
    // Needed so a receiver can serve a saved plain file back by re-opening it.
    mA.sourceOpener = veilSourceOpener;
    mB.sourceOpener = veilSourceOpener;
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });
  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  test(
    'A sends serve-from-source (never stored locally); B receives and holds '
    'it; A can pull its OWN file back from B by contentId',
    () async {
      final data = _rnd(400000, 51);
      // A serves straight from an in-memory "source" — the bytes are NEVER put
      // in A's own store (hasFile stays false for A), mirroring a large
      // serve-from-disk send whose source A later deletes.
      final cid = await mA.sendFileStreaming(
        b,
        'mine.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      expect(cid, isNotNull);

      // B downloads into its encrypted tier and becomes a holder.
      final bGot = mB.contentReceived.first;
      // Wait for the offer, then download.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if ((await sB.loadMessages(a.hex)).any((m) => m.fileContentId == cid)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await mB.downloadContent(a, cid!);
      await bGot.timeout(const Duration(seconds: 20));
      expect(await sB.loadFile(cid), data, reason: 'B holds the blob');

      // A never held the bytes.
      expect(await sA.hasFile(cid), isFalse);

      // A's source is gone — pull the identical bytes back FROM B.
      final aGot = mA.contentReceived.first;
      final r = await mA.downloadContent(b, cid);
      expect(r, ContentDownloadResult.started);
      final ev = await aGot.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(
        await sA.loadFile(cid),
        data,
        reason: 'A recovered its own file from the recipient',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'B saved the file to a PLAIN file on disk (not the encrypted tier); '
    'A can still pull its own file back — B serves from the saved file',
    () async {
      // Keep it an OFFER (no auto-download into the encrypted tier), so the
      // ONLY fetch is the plaintext-to-disk one and B never holds an encrypted
      // blob — the case this feature must cover.
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      final data = _rnd(400000, 61);
      final cid = await mA.sendFileStreaming(
        b,
        'plain.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      expect(cid, isNotNull);

      // Wait for B's offer.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if ((await sB.loadMessages(a.hex)).any((m) => m.fileContentId == cid)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // B downloads UNENCRYPTED straight to a plaintext file on disk.
      final dir = await Directory.systemTemp.createTemp('xveil-plainserve');
      final path = '${dir.path}/plain.bin';
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final bSaved = mB.contentReceived.firstWhere((e) => e.contentId == cid);
      final raf = await File(path).open(mode: FileMode.write);
      await mB.downloadContentToFile(
        a,
        cid!,
        path,
        write: (o, bytes) async {
          await raf.setPosition(o);
          await raf.writeFrom(bytes);
        },
        close: () async {
          await raf.close();
        },
      );
      final saved = await bSaved.timeout(const Duration(seconds: 20));
      expect(saved.savedToPath, path);
      expect(await File(path).readAsBytes(), data);
      // The blob is NOT in B's encrypted store — it lives only as the plain file.
      expect(await sB.hasFile(cid), isFalse);

      // A's source is gone — pull it back FROM B, who serves the plain file.
      final aGot = mA.contentReceived.first;
      final r = await mA.downloadContent(b, cid);
      expect(r, ContentDownloadResult.started);
      final ev = await aGot.timeout(const Duration(seconds: 20));
      expect(ev.contentId, cid);
      expect(
        await sA.loadFile(cid),
        data,
        reason: 'A recovered its file from B, served from B\'s saved plain file',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
