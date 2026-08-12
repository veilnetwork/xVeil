import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/blob_sources.dart';
import 'package:xveil/api/direct_file_api.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

// What the automation API says about a 1:1 FILE, and whether the caller can act
// on it.
//
// The defect these cover, reproduced live between two endpoints: A sends B a
// 200 KB file, and B's message list showed
// `{"body":"📎 probe200k.bin","fileName":"probe200k.bin"}` — a file, visibly,
// with no handle of any kind on it. `GET /v1/files/download` 404'd on every id
// a caller could reach for, and there was no route to ask for the bytes. The
// SENDER's row for the same file did carry a handle, which is how it survived:
// it looks correct from the side that sent it.

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    peer?._in.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
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

Future<Uint8List?> _drain(Storage storage, String key) async {
  final source = await storedBlobSource(storage, key);
  return source == null ? null : await drainBlobSource(source);
}

void main() {
  group('the pure projection', () {
    Message file({String? fileId, String? fileContentId, int? size}) => Message(
      id: 'm1',
      conversationId: 'c1',
      direction: MessageDirection.incoming,
      body: '📎 probe200k.bin',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      status: MessageStatus.delivered,
      fileId: fileId,
      fileName: 'probe200k.bin',
      fileSize: size,
      fileContentId: fileContentId,
      thumb: fileContentId == null ? null : 'iVBORw0KGgo=',
    );

    test('an OFFERED file carries a handle a caller can act on', () {
      final json = apiMessageJson(
        file(fileContentId: 'c' * 64, size: 204800),
        downloaded: false,
      );
      // The whole defect in one assertion: before the fix this map had NO key
      // naming the file at all beyond its display name.
      expect(
        json['fileContentId'],
        'c' * 64,
        reason: 'the offer handle must be reachable over the API',
      );
      expect(json['fileSize'], 204800, reason: 'known before any byte moves');
      expect(json['thumb'], 'iVBORw0KGgo=');
      expect(json['fileDownloaded'], isFalse);
      expect(
        json.containsKey('fileId'),
        isFalse,
        reason: 'an offered file genuinely has no store key yet',
      );
    });

    test('a file already held still serializes fileId, unchanged', () {
      final json = apiMessageJson(file(fileId: 'blob-7'), downloaded: true);
      // The regression guard: the five original fields and `fileId` keep their
      // exact old spelling and values. Additive only.
      expect(json['id'], 'm1');
      expect(json['body'], '📎 probe200k.bin');
      expect(json['direction'], 'incoming');
      expect(json['sentAt'], 1700000000000);
      expect(json['status'], 'delivered');
      expect(json['fileName'], 'probe200k.bin');
      expect(json['fileId'], 'blob-7');
      expect(json['fileDownloaded'], isTrue);
      expect(
        json.containsKey('fileContentId'),
        isFalse,
        reason: 'nothing invented for a message that has no content handle',
      );
    });

    test('a plain text message gains no file keys', () {
      final json = apiMessageJson(
        Message(
          id: 'm2',
          conversationId: 'c1',
          direction: MessageDirection.outgoing,
          body: 'hello',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1),
          status: MessageStatus.sent,
        ),
        downloaded: false,
      );
      expect(json.keys.toSet(), {
        'id',
        'body',
        'direction',
        'sentAt',
        'status',
      });
    });
  });

  group('twin drift', () {
    // The GUI controller and the headless daemon each used to spell this map
    // out. They agreed on five fields and made the SAME mistake on the sixth,
    // which is what a pair of copies buys you. Neither may hold a copy again.
    test('both hosts project 1:1 messages through the one shared serializer', () {
      for (final path in const [
        'lib/state/api_server.dart',
        'lib/headless/headless_runtime.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source.contains('apiMessagesJson('),
          isTrue,
          reason: '$path must project messages through the shared serializer',
        );
        expect(
          source.contains("'sentAt':"),
          isFalse,
          reason:
              '$path builds a message map of its own again — that is how the '
              'two drifted the first time',
        );
      }
    });
  });

  group('live, two endpoints', () {
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
      const fast = Duration(milliseconds: 60);
      mA = MessagingService(
        tA,
        sA,
        contentReRequestInterval: fast,
        contentPacing: Duration.zero,
      )..start();
      mB = MessagingService(
        tB,
        sB,
        contentReRequestInterval: fast,
        contentPacing: Duration.zero,
      )..start();
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: a, status: ContactStatus.accepted),
      );
    });

    tearDown(() async {
      await mA.dispose();
      await mB.dispose();
    });

    Future<List<Message>> waitFiles(
      HiddenVolumeStorage s,
      NodeId peer,
      int n, {
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final files = (await s.loadMessages(
          peer.hex,
        )).where((m) => m.isFile).toList();
        if (files.length >= n) return files;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return (await s.loadMessages(peer.hex)).where((m) => m.isFile).toList();
    }

    Uint8List rnd(int n, int seed) {
      final r = Random(seed);
      return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
    }

    test(
      'a received large file: offered handle → fetch → download yields the '
      'exact bytes',
      () async {
        final data = rnd(3 * 1024 * 1024, 21); // > the auto-download cap
        await mA.sendFile(b, data, 'probe.bin');
        final offered = await waitFiles(sB, a, 1);
        expect(offered, hasLength(1));

        // 1. B's /v1/messages view of the offer.
        final listed = (await apiMessagesJson(
          await sB.loadMessages(a.hex),
          sB,
        )).firstWhere((m) => m['fileName'] == 'probe.bin');
        final handle = (listed['fileId'] ?? listed['fileContentId']) as String?;
        expect(
          handle,
          isNotNull,
          reason:
              'THE DEFECT: a received file used to arrive over the API with no '
              'handle of any kind — visible and unobtainable',
        );
        expect(listed['fileSize'], data.length);
        expect(listed['fileDownloaded'], isFalse);

        // 2. …and the bytes really are not here yet, so the projection is not
        //    merely optimistic.
        expect(await _drain(sB, handle!), isNull);

        // 3. The fetch step that did not exist.
        final received = mB.contentReceived.first;
        expect(
          await fetchDirectFile(sB, mB, a.hex, listed['id'] as String),
          isNull,
          reason: 'the fetch must be accepted',
        );
        await received.timeout(const Duration(seconds: 30));

        // 4. …after which the SAME handle downloads the SAME bytes.
        expect(await _drain(sB, handle), data);
        final after = (await apiMessagesJson(
          await sB.loadMessages(a.hex),
          sB,
        )).firstWhere((m) => m['fileName'] == 'probe.bin');
        expect(
          after['fileDownloaded'],
          isTrue,
          reason: 'and the list now says so',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('fetching a file already held succeeds without asking the network',
        () async {
      final data = rnd(3 * 1024 * 1024, 22);
      await mA.sendFile(b, data, 'twice.bin');
      final offered = await waitFiles(sB, a, 1);
      final received = mB.contentReceived.first;
      await fetchDirectFile(sB, mB, a.hex, offered.single.id);
      await received.timeout(const Duration(seconds: 30));
      expect(
        await fetchDirectFile(sB, mB, a.hex, offered.single.id),
        isNull,
        reason: 'idempotent: a second fetch is a no-op success',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test("the SENDER's own row keeps fileId exactly as it was", () async {
      final data = rnd(64 * 1024, 23);
      await mA.sendFile(b, data, 'mine.bin');
      final mine = (await apiMessagesJson(
        await sA.loadMessages(b.hex),
        sA,
      )).firstWhere((m) => m['fileName'] == 'mine.bin');
      expect(
        mine['fileId'],
        isA<String>(),
        reason: 'the field the old serializer emitted must still be emitted',
      );
      expect(
        await _drain(sA, mine['fileId'] as String),
        data,
        reason: 'and it still downloads, unchanged',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a fetch naming no file, or a peer that is not one, is refused',
        () async {
      expect(
        await fetchDirectFile(sB, mB, a.hex, 'no-such-message'),
        'message attachment not found',
      );
      expect(
        await fetchDirectFile(sB, mB, 'not-a-node-id', 'whatever'),
        'invalid peer',
      );
      await mA.sendText(b, 'just words');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final text = (await sB.loadMessages(a.hex)).firstWhere((m) => !m.isFile);
      expect(
        await fetchDirectFile(sB, mB, a.hex, text.id),
        'message attachment not found',
        reason: 'a text message is not a file handle',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
