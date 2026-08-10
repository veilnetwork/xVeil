import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/serve_source.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

// Audit X-02, the racy half.
//
// `POST /v1/files` used to look the path up THREE times after it had been
// authorized: `exists()`, then `length()`, then `open()`. A name pointed
// somewhere else between the second and the third produced an offer describing
// one file's SIZE while hashing and serving another file's BYTES — and that
// combination is the one an honest receiver cannot tell from a real send,
// because the manifest is internally consistent with the bytes it is given.
//
// One descriptor removes the disagreement. It does not remove the window
// between the API edge's check and the open; nothing available in Dart does
// (no `openat`, no `O_NOFOLLOW`, no `fstat`).
//
// That residue is narrowed by `veilOpenPinnedSource`, which stamps the name's
// identity on either side of the open and refuses before anything is offered
// (audit X-01, covered by `send_source_pinning_test.dart`), and what is left
// of it is DETECTED by comparing the stamp across the read — reported after
// the fact, which is what "detection" means and all it means.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Blackhole implements VeilTransport {
  _Blackhole(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();

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
  }) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

late Storage _activeStorage;

class _ReadyAppController extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(
      nodeId: NodeId.fromHex('11' * 32),
      displayName: 'A',
    ),
  );
}

void main() {
  late Directory workdir;

  setUp(() async {
    workdir = await Directory.systemTemp.createTemp('xveil-send-source');
    ApiServerController.debugBindPort = 0;
  });
  tearDown(() async {
    ApiServerController.debugBindPort = kApiPort;
    ApiServerController.debugSourceOpener = veilOpenSourceForSend;
    await workdir.delete(recursive: true);
  });

  test('the send opens the path once: size and bytes come from one descriptor',
      () async {
    final target = File('${workdir.path}/named.bin');
    await target.writeAsBytes(Uint8List(1000)..fillRange(0, 1000, 0xAA));
    final decoy = File('${workdir.path}/decoy.bin');
    await decoy.writeAsBytes(Uint8List(5000)..fillRange(0, 5000, 0xBB));

    final source = await veilOpenSourceForSend(target.path);
    expect(source, isNotNull);
    addTearDown(source!.close);

    // The NAME now means a different file, of a different length. A `rename`
    // is the cheap version of the attack: it needs no write access to the file
    // being replaced, and it defeats a symlink resolution done a moment ago
    // without touching anything inside the allowed folder.
    await decoy.rename(target.path);
    expect(
      await File(target.path).length(),
      5000,
      reason: 'the swap has to have really happened, or this proves nothing',
    );

    expect(
      source.size,
      1000,
      reason:
          'the size came from the NAME after the swap — the offer would '
          'describe one file while serving another',
    );
    final bytes = await source.read(0, 1000);
    expect(bytes, hasLength(1000));
    expect(
      bytes.every((byte) => byte == 0xAA),
      isTrue,
      reason: 'the reads followed the name instead of the opened file',
    );
  });

  group('POST /v1/files', () {
    late ProviderContainer container;
    late ApiServerController controller;
    late MessagingService messaging;
    late HiddenVolumeStorage storage;
    final peer = _id(2);

    Future<void> boot() async {
      final log = FakeKvLogStore();
      storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) => log,
      );
      expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
      await storage.putSetting(
        'api.tokens',
        jsonEncode([
          {
            'id': 'id-a',
            'name': 'bot',
            'token': 'tok-a',
            'ro': false,
            'fr': [workdir.path],
          },
        ]),
      );
      await storage.putSetting('api.enabled', '1');
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      _activeStorage = storage;

      messaging = MessagingService(_Blackhole(_id(1)), storage)..start();
      addTearDown(messaging.dispose);
      container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          storageProvider.overrideWith((ref) => _activeStorage),
          groupServiceProvider.overrideWithValue(null),
          messagingServiceProvider.overrideWithValue(messaging),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(storage.close);
      container.read(apiServerControllerProvider);
      controller = container.read(apiServerControllerProvider.notifier);
      for (var i = 0; i < 400 && controller.boundPort == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.boundPort, isNotNull, reason: 'the API never came up');
    }

    Future<(int status, Map<String, dynamic> body)> postFile(String path) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${controller.boundPort}/v1/files'),
        );
        req.headers.set('Authorization', 'Bearer tok-a');
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'to': peer.hex, 'path': path}));
        final res = await req.close();
        final body = await utf8.decodeStream(res);
        return (res.statusCode, jsonDecode(body) as Map<String, dynamic>);
      } finally {
        client.close(force: true);
      }
    }

    test('an honest send still works', () async {
      // THE CONTROL. Refusing everything would close this finding and break
      // the endpoint, and the two are indistinguishable from the tests below
      // on their own.
      await boot();
      final file = File('${workdir.path}/holiday.bin');
      await file.writeAsBytes(Uint8List(64000)..fillRange(0, 64000, 0x7));

      final (status, body) = await postFile(file.path);
      expect(status, 200, reason: 'body was $body');
      expect(body['ok'], isTrue);

      final messages = await storage.loadMessages(peer.hex);
      expect(messages, hasLength(1));
      expect(messages.single.fileName, 'holiday.bin');
      expect(messages.single.fileSize, 64000);
    });

    test('the size and the bytes come from the opener, never from the name '
        'again', () async {
      // The old send asked the NAME three times after it had been authorized:
      // `exists()`, `length()`, then a separate `open()`. Each of those is a
      // fresh lookup, and the size ended up describing whatever the name meant
      // at ITS moment rather than what the read handle was attached to.
      //
      // So: an opener whose descriptor holds 48000 bytes, over a path whose
      // NAME holds 1000. That is precisely the disagreement a swap between the
      // `length()` and the `open()` used to produce, staged without a race.
      // The offer must describe the descriptor.
      await boot();
      final bytes = Uint8List(48000)..fillRange(0, 48000, 0x5);
      final named = File('${workdir.path}/two-sizes.bin');
      await named.writeAsBytes(Uint8List(1000));
      ApiServerController.debugSourceOpener = (path) async => (
        size: bytes.length,
        read: (int offset, int length) async =>
            Uint8List.sublistView(bytes, offset, offset + length),
        close: () async {},
      );

      final (status, body) = await postFile(named.path);
      expect(status, 200, reason: 'body was $body');
      final messages = await storage.loadMessages(peer.hex);
      expect(
        messages.single.fileSize,
        48000,
        reason:
            'the offer took its size from the NAME while the bytes came from '
            'the descriptor — the two describing different files is exactly '
            'what an honest receiver cannot detect',
      );
    });

    test('a source that changes under the read is reported, not passed off as '
        'a clean send', () async {
      await boot();
      final file = File('${workdir.path}/changing.bin');
      await file.writeAsBytes(Uint8List(64000)..fillRange(0, 64000, 0x7));

      // Deterministic: the change happens from INSIDE the read pass, which is
      // the moment the detection is about. Waiting on a timer to land in the
      // right window would make this test a coin toss.
      final real = veilOpenSourceForSend;
      ApiServerController.debugSourceOpener = (path) async {
        final opened = await real(path);
        if (opened == null) return null;
        var touched = false;
        return (
          size: opened.size,
          read: (int offset, int length) async {
            final data = await opened.read(offset, length);
            if (!touched) {
              touched = true;
              await File(path).setLastModified(
                DateTime.now().add(const Duration(minutes: 5)),
              );
            }
            return data;
          },
          close: opened.close,
        );
      };

      final (status, body) = await postFile(file.path);
      expect(status, 400, reason: 'body was $body');
      expect(
        body['error'],
        contains('changed while it was being read'),
        // Status alone would not do: the endpoint answers 400 for a bad peer,
        // an unreadable source and a refused contact too, so a test that only
        // checked the code would pass against a build that never detected
        // anything.
        reason:
            'the caller was told the send was fine while the file it named '
            'had moved under the read',
      );
    });
  });

  // The GROUP twin, guarded structurally rather than by racing.
  //
  // The 1:1 send is testable end-to-end above because it streams inline: the
  // decoy can be swapped in and the offer inspected. A group send registers a
  // source to be served on demand later, so there is no read to bracket and
  // no moment to swap at — the window is between two syscalls inside the
  // sender itself, and staging that deterministically is not possible.
  //
  // What CAN be stated exactly is the shape that removes the window: the size
  // and the bytes come from one descriptor, so there is no second lookup to
  // disagree with the first. That is a property of the source, and it is what
  // this checks — for BOTH senders, so the twin cannot drift again (report9
  // #7 found the group path still on the old three-lookup shape long after
  // X-02 fixed the 1:1 one).
  test('neither sender takes its size from a second lookup of the name', () {
    // The 1:1 sender opens through `debugSourceOpener`, whose production
    // value is the helper — asserted separately below, so the indirection
    // cannot become a way around this guard.
    const senders = <String, (String, String)>{
      'lib/state/api_server.dart': (
        'Future<String?> _sendFile(',
        'debugSourceOpener',
      ),
      'lib/api/group_api_adapter.dart': (
        'Future<({String? error, String? contentId})> sendFile(',
        'veilOpenPinnedSource',
      ),
    };

    expect(
      File('lib/state/api_server.dart')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s+'), ' '),
      contains('debugSourceOpener = veilOpenSourceForSend'),
      reason:
          'the injectable opener no longer defaults to the single-descriptor '
          'helper, so the guard below proves nothing about production',
    );
    // The senders open through `veilOpenPinnedSource` now, which is a wrapper.
    // Without this the guard below would be satisfied by a wrapper that looked
    // the name up twice inside itself — the very shape it exists to forbid,
    // moved one call deeper.
    expect(
      File('lib/data/serve_source.dart')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s+'), ' '),
      contains('await (opener ?? veilOpenSourceForSend)(path)'),
      reason:
          'veilOpenPinnedSource no longer opens through the single-descriptor '
          'helper, so routing the senders through it proves nothing',
    );

    for (final entry in senders.entries) {
      final source = File(entry.key).readAsStringSync();
      final start = source.indexOf(entry.value.$1);
      expect(
        start,
        isNot(-1),
        reason:
            'the sender ${entry.value.$1} is gone from ${entry.key} — this '
            'guard now checks nothing, which is worse than it failing',
      );

      // Brace-count the method body. A mis-parse makes this fail loudly; it
      // cannot make it pass quietly.
      // The body brace, not the first one: a record return type spells
      // `({String? error, ...})` right there in the signature.
      final asyncAt = source.indexOf('async {', start);
      expect(
        asyncAt,
        isNot(-1),
        reason: '${entry.value.$1} is no longer an async method',
      );
      final open = asyncAt + 'async '.length;
      var depth = 0;
      var end = -1;
      for (var i = open; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      expect(end, isNot(-1), reason: 'could not find the end of ${entry.value}');
      final body = source.substring(open, end);

      expect(
        body,
        contains(entry.value.$2),
        reason:
            '${entry.key}: the sender must open the path through the one '
            'helper that hands back the size WITH the descriptor',
      );
      expect(
        body,
        isNot(contains('.length()')),
        reason:
            '${entry.key}: the size is coming from a second lookup of the '
            'name. Between it and the open the name can mean another file, '
            'and the offer then describes one file and serves another — the '
            'one combination an honest receiver cannot detect',
      );
      expect(
        body,
        isNot(contains('.exists()')),
        reason:
            '${entry.key}: a third lookup of the name, and it proves nothing '
            'the open does not prove better',
      );
    }
  });
}
