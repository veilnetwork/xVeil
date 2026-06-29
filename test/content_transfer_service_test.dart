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
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// 1:1 link that can selectively drop pieceChunk frames (to exercise the
/// re-request path) — everything else is delivered.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  // Drop the first delivery of these (pieceIndex) chunks, once each.
  final Set<int> dropPiecesOnce = {};
  // Drop the FIRST contentManifest (simulate the offer's one-shot manifest being
  // lost / a receiver restart) so the reoffer path must re-fetch it.
  bool dropManifestOnce = false;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.pieceChunk) {
      final f = parsePieceChunk(env.body);
      if (dropPiecesOnce.remove(f.pieceIndex)) return; // drop once → forces re-request
    }
    if (env.kind == WireKind.contentManifest && dropManifestOnce) {
      dropManifestOnce = false;
      return; // the offer's manifest is "lost" → receiver must reoffer
    }
    peer?._in.add(InboundMessage(src: _me, payload: payload));
  }

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

void main() {
  late NodeId a, b;
  late _Link tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _Link(a);
    tB = _Link(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    // Short re-request cadence so the drop-recovery test doesn't wait seconds.
    const fast = Duration(milliseconds: 120);
    mA = MessagingService(tA, sA,
        contentReRequestInterval: fast, contentPacing: Duration.zero)
      ..start();
    mB = MessagingService(tB, sB,
        contentReRequestInterval: fast, contentPacing: Duration.zero)
      ..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });

  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  Uint8List _rnd(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  test('content transfer: advertise → request → serve → verify → reassemble '
      '(multi-piece, hash-verified end to end)', () async {
    final data = _rnd(300000, 7); // ~2 pieces at the 256 KiB adaptive size
    final got = mB.contentReceived.first;
    await mA.sendContent(b, data, 'movie.bin');
    final received = await got.timeout(const Duration(seconds: 10));
    expect(received.name, 'movie.bin');
    expect(await sB.loadFile(received.contentId), data, reason: 'verified whole == original');
  });

  test('a dropped piece is re-requested and the transfer still completes',
      () async {
    final data = _rnd(300000, 8);
    // Content flows A→B over tA.send — drop a piece-1 chunk there, once.
    tA.dropPiecesOnce.add(1);
    final got = mB.contentReceived.first;
    await mA.sendContent(b, data, 'doc.bin');
    // B's re-request timer asks A again for the missing piece; it lands next time.
    final received = await got.timeout(const Duration(seconds: 10));
    expect(await sB.loadFile(received.contentId), data, reason: 'recovered the dropped piece');
  });

  test('large file becomes delivered only after receiver verifies and stores it',
      () async {
    final data = _rnd(1024 * 1024 + 1, 9); // force the content-layer path
    final got = mB.contentReceived.first;
    await mA.sendFile(b, data, 'large.bin');

    final before = await sA.loadMessages(b.hex);
    expect(before.single.status, MessageStatus.sent,
        reason: 'manifest advertisement is not file delivery');

    final received = await got.timeout(const Duration(seconds: 20));
    expect(await sB.loadFile(received.contentId), data);

    MessageStatus? status;
    for (var i = 0; i < 100; i++) {
      status = (await sA.loadMessages(b.hex)).single.status;
      if (status == MessageStatus.delivered) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(status, MessageStatus.delivered,
        reason: 'whole-content completion ACK must flip sender status');
  });

  test('a large send is SERVED FROM SOURCE (no duplicated copy on the sender) '
      'and still delivers + verifies on the receiver', () async {
    final source = _rnd(700000, 11); // ~3 pieces; stands in for a too-big file
    var closed = false;
    // The analogue of RandomAccessFile.read(offset, length): the sender reads
    // each chunk straight from the source on request — never the whole file.
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(source, offset, offset + length);

    final got = mB.contentReceived.first;
    await mA.sendFileStreaming(b, 'huge.bin', source.length, read,
        close: () async => closed = true);

    final cid = ContentManifest.fromBytes('huge.bin', source).contentId;
    final received = await got.timeout(const Duration(seconds: 20));
    expect(received.contentId, cid, reason: 'streamed id == in-RAM id');
    expect(await sB.loadFile(received.contentId), source,
        reason: 'receiver reassembled + verified the whole from the served source');
    // The SENDER keeps NO copy — it already has the original, so storing one
    // would duplicate it (and a big copy is what overflowed the in-volume index).
    expect(await sA.hasFile(cid), isFalse,
        reason: 'serve-from-source: sender stores nothing');

    // Status flips to delivered once the receiver has the whole content.
    MessageStatus? status;
    for (var i = 0; i < 200; i++) {
      status = (await sA.loadMessages(b.hex)).single.status;
      if (status == MessageStatus.delivered) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(status, MessageStatus.delivered);
    // The source handle is still held while serving (closed only on eviction).
    expect(closed, isFalse, reason: 'source stays open for re-requests');
    await mA.dispose(); // dispose releases it
    expect(closed, isTrue, reason: 'dispose closes the serve-from-source handle');
  });

  test('a download with no live manifest RE-REQUESTS it from the sender and '
      'resumes (offer survived a restart, manifest did not)', () async {
    final data = _rnd(300000, 41);
    final cid = ContentManifest.fromBytes('r.bin', data).contentId;
    // A's first advertise is lost → A is SERVING but B never registered the offer.
    tA.dropManifestOnce = true;
    await mA.sendContent(b, data, 'r.bin');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(mB.fetchingCount, 0, reason: 'B has no manifest → not fetching');

    // B taps download → no live offer → asks A to re-advertise → A re-sends the
    // manifest → B fetches + completes.
    final got = mB.contentReceived.first;
    final r = await mB.downloadContent(a, cid);
    expect(r, ContentDownloadResult.requestedReoffer);
    final ev = await got.timeout(const Duration(seconds: 20));
    expect(ev.contentId, cid);
    expect(await sB.loadFile(cid), data, reason: 'resumed + verified the whole');
  });

  test('download emits monotonic progress, ending at done == total', () async {
    final data = _rnd(300000, 31); // multi-piece, auto-downloads (< 2 MB cap)
    final events = <({String contentId, int done, int total})>[];
    final sub = mB.contentProgress.listen(events.add);
    addTearDown(sub.cancel);
    final got = mB.contentReceived.first;
    await mA.sendContent(b, data, 'p.bin');
    await got.timeout(const Duration(seconds: 10));

    expect(events, isNotEmpty, reason: 'progress is emitted per piece');
    expect(events.last.total, greaterThan(1), reason: 'multi-piece file');
    expect(events.last.done, events.last.total, reason: 'ends complete');
    for (var i = 1; i < events.length; i++) {
      expect(events[i].done, greaterThanOrEqualTo(events[i - 1].done),
          reason: 'progress never goes backwards');
    }
  });

  test('UNENCRYPTED download: pieces are written straight to a plaintext file; '
      'NOTHING is stored in the app; completion reports the path', () async {
    final data = _rnd(300000, 22); // multi-piece, served from source
    final cid = ContentManifest.fromBytes('clip.bin', data).contentId;
    // "Always ask" so the file stays an OFFER (not auto-downloaded) → the user
    // gets to choose the unencrypted-to-file path.
    await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0));
    Future<Uint8List> read(int o, int l) async =>
        Uint8List.sublistView(data, o, o + l);
    await mA.sendFileStreaming(b, 'clip.bin', data.length, read,
        close: () async {});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // B downloads it UNENCRYPTED to a plaintext file (a temp file stands in for
    // the user's picked path). Each verified piece is written at its offset.
    final dir = await Directory.systemTemp.createTemp('xveil-plain');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final dest = '${dir.path}/clip.bin';
    final raf = await File(dest).open(mode: FileMode.write);
    final done = mB.contentReceived.firstWhere((e) => e.contentId == cid);

    final res = await mB.downloadContentToFile(a, cid, dest,
        write: (offset, bytes) async {
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
    }, close: () async {
      await raf.close();
    });
    expect(res, ContentDownloadResult.started);

    final ev = await done.timeout(const Duration(seconds: 20));
    expect(ev.savedToPath, dest, reason: 'completion reports the plaintext path');
    // The plaintext file on disk == the original bytes.
    expect(await File(dest).readAsBytes(), data);
    // NOTHING was stored in the app (no in-volume blob, no encrypted tier).
    expect(await sB.hasFile(cid), isFalse,
        reason: 'unencrypted-to-file keeps nothing in the app');
  });
}
