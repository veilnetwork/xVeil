import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

// `POST /v1/contacts` answered `200 {"ok":true}` to a bare hex node id.
//
// Nothing was delivered, and nothing could be. A node id is BLAKE3 of the
// peer's public key (see [BootstrapInvite.nodeId]) — a hash — so the node was
// handed no key to seal a first contact to. Measured against a live peer on a
// three-endpoint sweep: eighty seconds, nothing at the other end, the sender
// left holding a `pendingOutgoing` contact, and the retry failing with the
// node's own `PeerUnresolved`. The same call with the peer's invite URI was
// delivered in eight seconds.
//
// The endpoint now refuses the form it cannot deliver, and says what to send
// instead. The CONTROL below matters as much as the refusal: an endpoint that
// refused everything would close this finding and break contact requests, and
// the two are indistinguishable from the refusal test alone.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A relay that stores whatever it is handed.
///
/// The control below asks the endpoint to make a real request, and a request
/// with nowhere to deposit it is now REFUSED rather than silently reported as
/// sent — which is the defect this fixture would otherwise re-encode. Give it
/// a relay so the control exercises a complete success.
class _RecordingRelay implements MailboxSink {
  final stashed = <Uint8List>[];

  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async => stashed.add(payload);

  @override
  void nudgeDrain() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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

/// A node controller with no timers (the fake one schedules periodic work that
/// outlives the test).
class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

late Storage _activeStorage;

class _ReadyAppController extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId.fromHex('11' * 32), displayName: 'A'),
  );
}

void main() {
  setUp(() => ApiServerController.debugBindPort = 0);
  tearDown(() => ApiServerController.debugBindPort = kApiPort);

  group('the refusal, on its own', () {
    // The decision is one function so the API and its headless twin cannot
    // drift into disagreeing about what is deliverable.

    test('an invite is what the node can act on', () {
      final invite = BootstrapInvite(
        publicKey: Uint8List(32),
        nonce: Uint8List(8),
      );
      expect(contactRequestRefusal(invite.toUri()), isNull);
      // Pasted targets arrive with whitespace; `parse` trims, so this must too
      // or the two disagree about the same string.
      expect(contactRequestRefusal('  ${invite.toUri()}\n'), isNull);
    });

    test('a bare node id is refused, naming what to send instead', () {
      final refusal = contactRequestRefusal('ab' * 32);
      expect(refusal, isNotNull);
      expect(
        refusal,
        contains(BootstrapInvite.scheme),
        reason: 'a refusal that does not say what to supply instead leaves the '
            'caller exactly as stuck as the silent failure did',
      );
    });

    test('the headless twin consults the same decision', () {
      // Both edges shipped the same defect. This is the cheap guarantee that
      // fixing one did not leave the other answering `ok` — the twin has no
      // seam of its own to drive from a test.
      final source = File(
        'lib/headless/headless_runtime.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('contactRequestRefusal(target)'),
        reason: 'the headless contact request no longer refuses an '
            'undeliverable target',
      );
    });
  });

  group('POST /v1/contacts', () {
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
          {'id': 'id-a', 'name': 'bot', 'token': 'tok-a', 'ro': false},
        ]),
      );
      await storage.putSetting('api.enabled', '1');
      _activeStorage = storage;

      messaging = MessagingService(_Blackhole(_id(1)), storage)..start();
      messaging.attachMailbox(_RecordingRelay());
      addTearDown(messaging.dispose);
      container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_ReadyAppController.new),
          storageProvider.overrideWith((ref) => _activeStorage),
          groupServiceProvider.overrideWithValue(null),
          messagingServiceProvider.overrideWithValue(messaging),
          // A stack with a node behind it, so "node unavailable" cannot be the
          // reason anything below is refused.
          realStackProvider.overrideWith(
            (ref) => RealVeilStack.overParts(
              controller: _NoopNode(),
              transport: _Blackhole(_id(1)),
              myInvite: BootstrapInvite(
                publicKey: Uint8List(32),
                nonce: Uint8List(8),
              ),
            ),
          ),
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

    Future<(int, Map<String, dynamic>)> post(String target) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${controller.boundPort}/v1/contacts'),
        );
        req.headers.set('Authorization', 'Bearer tok-a');
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'target': target, 'greeting': 'hello'}));
        final res = await req.close();
        final body = await utf8.decodeStream(res);
        return (res.statusCode, jsonDecode(body) as Map<String, dynamic>);
      } finally {
        client.close(force: true);
      }
    }

    test('an invite is accepted and really does become a request', () async {
      // THE CONTROL, first: the endpoint must still work, or every assertion
      // about the refusal is satisfied by an endpoint that does nothing at all.
      await boot();
      final invite = BootstrapInvite(
        publicKey: Uint8List(32)..fillRange(0, 32, 9),
        nonce: Uint8List(8),
      );

      final (status, body) = await post(invite.toUri());
      expect(status, 200, reason: 'body was $body');
      expect(body['ok'], isTrue);

      // What "ok" is supposed to mean: a request exists, addressed to the node
      // the invite names, carrying the greeting that was posted.
      final contact = await storage.getContact(invite.nodeId);
      expect(contact?.status, ContactStatus.pendingOutgoing);
      final messages = await storage.loadMessages(invite.nodeId.hex);
      expect(messages.single.body, 'hello');
    });

    test('a bare node id is refused, and leaves nothing behind', () async {
      await boot();

      final (status, body) = await post(peer.hex);
      expect(
        status,
        400,
        reason: 'a request the node cannot seal was answered with success: '
            'body was $body',
      );
      expect(
        body['error'],
        contains(BootstrapInvite.scheme),
        reason: 'the refusal has to say what to supply instead',
      );

      // And the refusal is a refusal, not a failure after the fact. The shipped
      // path wrote a `pendingOutgoing` contact and stored the greeting before
      // discovering it had nobody to send it to — which is also what made a
      // retry look admissible: the failing call left the evidence that the peer
      // was known.
      expect(await storage.getContact(peer), isNull);
      expect(await storage.loadMessages(peer.hex), isEmpty);
    });
  });
}
