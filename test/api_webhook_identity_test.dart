import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/webhook_pump.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

// Audit X-07, the webhook half of the same leak XV-10 closed for the WebSocket
// feed.
//
// The events this pushes carry `from` (a peer's node id) and `preview` (the
// text of the message). Cancelling the SUBSCRIPTION — all the GUI controller
// did on an identity switch — stops new events and leaves every delivery
// already started running to completion: two attempts, two seconds apart, five
// seconds of deadline each. About twelve seconds during which the identity the
// app has just LEFT keeps talking to the webhook it configured.
//
// The proof required here is positive. Not "no errors were logged" — that is
// what the leak looked like all along. The old address must receive nothing,
// counted, after the switch.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A transport that goes nowhere, with a hatch for pushing a frame in as if it
/// had arrived over the wire — the shortest path to a real `incoming` notice.
class _BlackholeTransport implements VeilTransport {
  _BlackholeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();

  void inject(InboundMessage m) => _inbound.add(m);

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
  }) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// A webhook target that records every event body it is handed and then
/// answers 500.
///
/// 500 is the point: it means "not delivered", which is exactly what schedules
/// the retry that used to outlive the identity that scheduled it. A target
/// that answered 200 would take the first attempt and never expose the window.
class _RecordingTarget {
  _RecordingTarget._(this._server);

  static Future<_RecordingTarget> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = _RecordingTarget._(server);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      try {
        target.events.add(jsonDecode(body) as Map<String, dynamic>);
      } catch (_) {
        target.events.add({'unparsed': body});
      }
      req.response.statusCode = 500;
      await req.response.close();
    });
    return target;
  }

  final HttpServer _server;
  final List<Map<String, dynamic>> events = [];

  String get url => 'http://127.0.0.1:${_server.port}/hook';
  Future<void> close() => _server.close(force: true);

  /// Wait (briefly) for [count] events, then return. Never fails on its own —
  /// the assertions do that, so a timeout reads as the count it actually saw.
  Future<void> waitFor(int count) async {
    for (var i = 0; i < 400 && events.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

late Storage _activeStorage;
late Identity _initialIdentity;

class _SwitchingAppController extends AppController {
  @override
  AppState build() => AppState(AppPhase.ready, identity: _initialIdentity);

  void expose(Identity identity, Storage storage) {
    _activeStorage = storage;
    ref.invalidate(storageProvider);
    state = AppState(AppPhase.ready, identity: identity);
  }
}

Future<HiddenVolumeStorage> _storageWith({
  required String token,
  String? webhook,
}) async {
  final log = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) => log,
  );
  expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
  await storage.putSetting(
    'api.tokens',
    jsonEncode([
      {'id': token, 'name': token, 'token': token, 'ro': false},
    ]),
  );
  await storage.putSetting('api.enabled', '1');
  if (webhook != null) await storage.putSetting('api.webhook', webhook);
  return storage;
}

void main() {
  setUp(() => ApiServerController.debugBindPort = 0);
  tearDown(() => ApiServerController.debugBindPort = kApiPort);

  test(
    'switching identity delivers nothing further to the previous webhook — '
    'the retry included',
    () async {
      final target = await _RecordingTarget.bind();
      final successor = await _RecordingTarget.bind();
      addTearDown(target.close);
      addTearDown(successor.close);

      final first = await _storageWith(token: 'tok-a', webhook: target.url);
      final second = await _storageWith(token: 'tok-b', webhook: successor.url);
      addTearDown(first.close);
      addTearDown(second.close);

      // One messaging pipeline, deliberately: the leak is that the PREVIOUS
      // identity's feed keeps feeding the PREVIOUS identity's webhook.
      final transport = _BlackholeTransport(_id(1));
      final messaging = MessagingService(transport, first)..start();
      addTearDown(messaging.dispose);
      final peer = _id(2);
      await messaging.acceptContact(peer);

      _activeStorage = first;
      _initialIdentity = Identity(
        nodeId: NodeId.fromHex('11' * 32),
        displayName: 'A',
      );
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_SwitchingAppController.new),
          storageProvider.overrideWith((ref) => _activeStorage),
          groupServiceProvider.overrideWithValue(null),
          messagingServiceProvider.overrideWithValue(messaging),
        ],
      );
      addTearDown(container.dispose);
      container.read(apiServerControllerProvider);
      final controller = container.read(apiServerControllerProvider.notifier);
      for (var i = 0; i < 400 && controller.boundPort == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.boundPort, isNotNull, reason: 'the API never came up');

      // CONTROL, and it has to come first: an event under identity A really
      // does reach A's webhook. Without this the rest of the test would pass
      // just as well against a webhook that never worked at all.
      transport.inject(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.message(
            'sent while A was active',
            id: 'm1',
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ).encode(),
        ),
      );
      await target.waitFor(1);
      expect(
        target.events,
        hasLength(1),
        reason: 'the webhook push must work before its silence proves anything',
      );
      expect(target.events.single['preview'], 'sent while A was active');
      expect(target.events.single['from'], peer.hex);

      // …and now the app moves to identity B, INSIDE the two-second wait that
      // separates the failed first attempt from its retry.
      (container.read(appControllerProvider.notifier)
              as _SwitchingAppController)
          .expose(
            Identity(nodeId: NodeId.fromHex('22' * 32), displayName: 'B'),
            second,
          );
      for (var i = 0; i < 400; i++) {
        if (container.read(apiServerControllerProvider).tokens.any(
          (t) => t.token == 'tok-b',
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        container.read(apiServerControllerProvider).webhookUrl,
        successor.url,
        reason: 'identity B has a webhook of its own now',
      );
      expect(
        target.events,
        hasLength(1),
        reason:
            'the switch has to land INSIDE the retry window or this test is '
            'measuring nothing — if this fires, the harness raced, not the code',
      );

      // An event under identity B. Two things have to be true of it at once,
      // and getting only one of them is how this is normally broken: it must
      // reach B's webhook (the feed is silenced per identity, not for good),
      // and it must not reach A's.
      transport.inject(
        InboundMessage(
          src: peer,
          payload: WireEnvelope.message(
            'sent after the switch',
            id: 'm2',
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ).encode(),
        ),
      );
      await successor.waitFor(1);
      expect(
        successor.events.map((e) => e['preview']),
        ['sent after the switch'],
        reason:
            'identity B never got its webhook — silencing A must be a handover, '
            'not a shutdown',
      );

      // Past the two-second retry of the first event, with room to spare.
      await Future<void>.delayed(const Duration(milliseconds: 3500));

      expect(
        target.events.map((e) => e['preview']),
        ['sent while A was active'],
        reason:
            'identity A\'s webhook received ${target.events.length} deliveries '
            'across the switch to B — it must have received exactly the one '
            'that predates it',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a retarget bars the retry the old address still had coming', () async {
    // The same guarantee at the pump, without the app around it: the barrier
    // is inside the retry loop because the WAIT between attempts is the window
    // a retarget lands in.
    final target = await _RecordingTarget.bind();
    addTearDown(target.close);

    final pump = WebhookPump(() => const Stream<Map<String, dynamic>>.empty());
    addTearDown(pump.close);
    await pump.setTarget(target.url);
    pump.enqueueForTest({
      'type': 'message',
      'from': 'aa' * 32,
      'preview': 'addressed to the old identity',
    });

    await target.waitFor(1);
    expect(
      target.events,
      hasLength(1),
      reason: 'the first attempt must land, or there is no retry to bar',
    );
    expect(target.events.single['preview'], 'addressed to the old identity');

    await pump.setTarget(null);
    await Future<void>.delayed(const Duration(milliseconds: 3500));

    expect(
      target.events,
      hasLength(1),
      reason:
          'the retry fired at an address the pump had already been taken off',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a retarget cuts the exchange in flight, not just the ones after it',
      () async {
    // The weaker half of the promise, and the reason the client is a FIELD
    // rather than one per attempt: there is something left to pull the plug
    // on. This does not un-send what is already on the wire — nothing does —
    // but the old target stops receiving the rest of it, immediately, instead
    // of when a five-second deadline gets around to it.
    // A raw socket, not an HttpServer: the question is what happens to the
    // CONNECTION, and `HttpResponse.done` does not report a peer that walks
    // away from a response the server has not started writing.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final arrived = Completer<void>();
    final severed = Completer<void>();
    server.listen((socket) {
      socket.listen(
        (_) {
          // Request bytes are in; answer nothing and hold the exchange open.
          if (!arrived.isCompleted) arrived.complete();
        },
        onDone: () {
          if (!severed.isCompleted) severed.complete();
        },
        onError: (Object _) {
          if (!severed.isCompleted) severed.complete();
        },
        cancelOnError: true,
      );
    });

    final pump = WebhookPump(() => const Stream<Map<String, dynamic>>.empty());
    addTearDown(pump.close);
    await pump.setTarget('http://127.0.0.1:${server.port}/hook');
    pump.enqueueForTest({'type': 'message', 'preview': 'mid-flight'});
    await arrived.future.timeout(const Duration(seconds: 10));

    await pump.setTarget(null);

    await severed.future.timeout(
      // Comfortably inside the 5 s attempt deadline: waiting THAT out is the
      // behaviour being ruled out.
      const Duration(seconds: 2),
      onTimeout: () => fail(
        'the retarget left the previous target holding a live exchange — it '
        'was only barred from being given a NEW one',
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a retarget does not hand the old queue to the new address', () async {
    // The other direction of the same rule: events addressed to A are not a
    // backlog to catch B up on.
    final delivered = <(String, String)>[];
    final gate = Completer<void>();
    final pump = WebhookPump(() => const Stream<Map<String, dynamic>>.empty());
    addTearDown(pump.close);
    pump.deliver = (t, e) async {
      delivered.add((t, e['preview'] as String));
      if (delivered.length == 1) await gate.future;
    };

    await pump.setTarget('http://127.0.0.1:1/a');
    pump.enqueueForTest({'preview': 'first'});
    await Future<void>.delayed(Duration.zero);
    pump.enqueueForTest({'preview': 'queued behind it'});
    await Future<void>.delayed(Duration.zero);

    await pump.setTarget('http://127.0.0.1:2/b');
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      delivered,
      [('http://127.0.0.1:1/a', 'first')],
      reason: 'the queued event belonged to the old address, not the new one',
    );
  });
}
