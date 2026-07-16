// Saved Messages FILE notes: saveFileNote stores the pick locally (whole-blob
// tier for small files, content-piece tier past the threshold) and records a
// normal file message row — with NOTHING on the wire (a note to self has no
// peer; the canon is local-only). saveFileNoteRef forwards an already-HELD
// file message into Saved as a copy-reference to the same stored blob, and
// honestly refuses when the blob was never downloaded.

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
Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

  /// Every payload handed to the transport — Saved Messages writes must
  /// leave this EMPTY (local-only canon).
  final List<Uint8List> sent = [];

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(payload);
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA, imageThumbMaker: (bytes) async => 'THUMB64')
      ..start();
    mB = MessagingService(tB, sB)..start();
  });

  test(
    'small file note lands locally with a loadable blob and no wire',
    () async {
      final data = _bytes(
        20000,
      ); // under the content threshold -> storeFile tier
      await mA.saveFileNote(data, 'note.bin');

      final saved = await sA.loadMessages(a.hex);
      final m = saved.singleWhere((m) => m.isFile);
      expect(m.direction, MessageDirection.outgoing);
      expect(m.fileName, 'note.bin');
      expect(m.fileSize, data.length);
      // Delivered, not sent: no peer will ever ack a note to self.
      expect(m.status, MessageStatus.delivered);
      expect(await sA.loadFile(m.fileId!), data);
      expect(
        tA.sent,
        isEmpty,
        reason: 'a note to self must never hit the wire',
      );
    },
  );

  test('image note carries the micro-thumb from the injected maker', () async {
    await mA.saveFileNote(_bytes(5000), 'pic.png');
    final m = (await sA.loadMessages(a.hex)).singleWhere((m) => m.isFile);
    expect(m.thumb, 'THUMB64');
  });

  test(
    'large file note takes the content tier (blob keyed by contentId)',
    () async {
      final data = _bytes(200 * 1024); // past the 128K content threshold
      await mA.saveFileNote(data, 'big.bin');

      final m = (await sA.loadMessages(a.hex)).singleWhere((m) => m.isFile);
      expect(m.fileName, 'big.bin');
      expect(m.fileSize, data.length);
      expect(m.status, MessageStatus.delivered);
      // The blob is held under the message's (content-id) key, piece-stored.
      expect(await sA.hasFile(m.fileId!), isTrue);
      expect(tA.sent, isEmpty, reason: 'no advertise/manifest for a self note');
    },
  );

  test(
    'forward of a HELD file message becomes a copy-reference in Saved',
    () async {
      // Real send A -> B so A holds the blob + the file message row.
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();
      final data = _bytes(9000);
      await mA.sendFile(b, data, 'doc.pdf');
      await _pump();
      final original = (await sA.loadMessages(
        b.hex,
      )).singleWhere((m) => m.isFile);

      tA.sent.clear();
      final ok = await mA.saveFileNoteRef(original, forwardedFrom: b.hex);
      expect(ok, isTrue);

      final saved = (await sA.loadMessages(a.hex)).singleWhere((m) => m.isFile);
      // Copy-REFERENCE: the same blob key, no second copy of the bytes.
      expect(saved.fileId, original.fileId);
      expect(saved.fileName, 'doc.pdf');
      expect(saved.forwardedFrom, b.hex);
      expect(saved.status, MessageStatus.delivered);
      expect(await sA.loadFile(saved.fileId!), data);
      expect(tA.sent, isEmpty, reason: 'forward-to-saved is purely local');
    },
  );

  test(
    'forward of an UNDOWNLOADED offer is refused (no row, no wire)',
    () async {
      final offer = Message(
        id: 'offer-1',
        conversationId: b.hex,
        direction: MessageDirection.incoming,
        body: '📎 ghost.bin',
        timestamp: DateTime.now(),
        // Offered-not-downloaded state: contentId known, no local blob.
        fileContentId: 'deadbeef' * 8,
        fileName: 'ghost.bin',
        fileSize: 12345,
      );
      final ok = await mA.saveFileNoteRef(offer);
      expect(ok, isFalse);
      expect((await sA.loadMessages(a.hex)).where((m) => m.isFile), isEmpty);
      expect(tA.sent, isEmpty);
    },
  );
}
