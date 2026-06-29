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

/// Datagram + reliable-stream loopback link between two peers.
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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async =>
      peer?._in.add(InboundMessage(src: _me, payload: payload));
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
    // Peer accepts the B-end; I keep the A-end.
    p._accepts.add((stream: _PipeEnd(bToA, aToB), src: _me));
    final w = p._acceptWaiter;
    p._acceptWaiter = null;
    w?.complete();
    return _PipeEnd(aToB, bToA);
  }

  @override
  Future<({ReliableStream stream, NodeId src})?> acceptStream(
      {Duration timeout = const Duration(seconds: 2)}) async {
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

  test('STREAM download: receiver pulls a multi-piece file over a reliable '
      'stream, verifies every piece, stores it (no datagram chunk/re-request)',
      () async {
    final data = _rnd(500000, 7); // ~2 pieces
    final cid = ContentManifest.fromBytes('movie.bin', data).contentId;
    // A advertises + serves-from-source; B is "always ask" so it stays an OFFER.
    await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0));
    await mA.sendFileStreaming(b, 'movie.bin', data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final got = mB.contentReceived.first;
    final r = await mB.downloadContent(a, cid);
    expect(r, ContentDownloadResult.started);
    final ev = await got.timeout(const Duration(seconds: 20));
    expect(ev.contentId, cid);
    expect(await sB.loadFile(cid), data, reason: 'pulled + verified the whole');
  });

  test('STREAM download to an UNENCRYPTED file writes the plaintext + nothing '
      'in the app', () async {
    final data = _rnd(400000, 9);
    final cid = ContentManifest.fromBytes('clip.bin', data).contentId;
    await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0));
    await mA.sendFileStreaming(b, 'clip.bin', data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final dir = await Directory.systemTemp.createTemp('xveil-stream');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final dest = '${dir.path}/clip.bin';
    final raf = await File(dest).open(mode: FileMode.write);
    final got = mB.contentReceived.first;
    final r = await mB.downloadContentToFile(a, cid, dest,
        write: (offset, bytes) async {
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
    }, close: () async {
      await raf.close();
    });
    expect(r, ContentDownloadResult.started);
    final ev = await got.timeout(const Duration(seconds: 20));
    expect(ev.savedToPath, dest);
    expect(await File(dest).readAsBytes(), data);
    expect(await sB.hasFile(cid), isFalse, reason: 'plaintext-to-file keeps nothing');
  });
}
