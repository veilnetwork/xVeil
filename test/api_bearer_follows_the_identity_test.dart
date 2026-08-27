// A bearer token belongs to one identity.
//
// The tokens are read out of that identity's own store, so a token authorizes
// what THAT identity can do. `ApiServer.stop()` closes the listener and the
// connections, but a handler already running is a Dart Future that nothing
// cancels, and every callback used to resolve its services when it ran. So a
// request authorized by A's token, still in flight when a concurrent
// `POST /v1/account/identity` moved the app to B, went on to greet a contact
// as B — with no bearer for B anywhere in it (report17 XV17-H7).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

late Storage _activeStorage;

class _SwitchingAppController extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId.fromHex('11' * 32), displayName: 'A'),
  );

  /// What `_activateOnline` does to the parts this test can see: the storage
  /// and the identity move, the phase does not.
  void switchTo(Identity identity, Storage storage) {
    _activeStorage = storage;
    ref.invalidate(storageProvider);
    state = AppState(AppPhase.ready, identity: identity);
  }
}

/// A stack whose `addContact` finishes when the test says so — the gap the
/// switch lands in.
class _SlowStack implements RealVeilStack {
  final gate = Completer<void>();
  var addContactCalls = 0;

  @override
  Future<void> addContact(BootstrapInvite invite) async {
    addContactCalls++;
    await gate.future;
  }

  @override
  BootstrapInvite get myInvite =>
      BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Counts what actually reached another person.
class _CountingMessaging implements MessagingService {
  final greeted = <NodeId>[];

  @override
  Future<void> sendRequest(NodeId peer, [String? greeting]) async =>
      greeted.add(peer);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<HiddenVolumeStorage> _storeWithToken(String token) async {
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
  return storage;
}

void main() {
  setUp(() => ApiServerController.debugBindPort = 0);
  tearDown(() => ApiServerController.debugBindPort = kApiPort);

  test('CONTROL: the endpoint works at all', () async {
    final a = await _storeWithToken('tok-a');
    addTearDown(a.close);
    _activeStorage = a;
    final stack = _SlowStack()..gate.complete();
    final messaging = _CountingMessaging();
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_SwitchingAppController.new),
        storageProvider.overrideWith((ref) => _activeStorage),
        groupServiceProvider.overrideWithValue(null),
        messagingServiceProvider.overrideWithValue(messaging),
        realStackProvider.overrideWith((ref) => stack),
      ],
    );
    addTearDown(container.dispose);
    container.read(apiServerControllerProvider);
    final controller = container.read(apiServerControllerProvider.notifier);
    for (var i = 0; i < 400 && controller.boundPort == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final invite = BootstrapInvite(
      publicKey: Uint8List(32)..fillRange(0, 32, 9),
      nonce: Uint8List(8),
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${controller.boundPort}/v1/contacts'),
    );
    req.headers.set('Authorization', 'Bearer tok-a');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'target': invite.toUri(), 'greeting': 'hello'}));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    expect(res.statusCode, 200, reason: body);
    expect(messaging.greeted, [invite.nodeId]);
  });

  test('a request A authorized does not greet a contact as B', () async {
    final a = await _storeWithToken('tok-a');
    final b = await _storeWithToken('tok-b');
    addTearDown(a.close);
    addTearDown(b.close);
    _activeStorage = a;

    final stack = _SlowStack();
    final messaging = _CountingMessaging();
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_SwitchingAppController.new),
        storageProvider.overrideWith((ref) => _activeStorage),
        groupServiceProvider.overrideWithValue(null),
        messagingServiceProvider.overrideWithValue(messaging),
        realStackProvider.overrideWith((ref) => stack),
      ],
    );
    addTearDown(container.dispose);

    container.read(apiServerControllerProvider);
    final controller = container.read(apiServerControllerProvider.notifier);
    for (var i = 0; i < 400 && controller.boundPort == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.boundPort, isNotNull, reason: 'the API never came up');
    // The server is rebound once more when the group service resolves, and
    // an ephemeral port is a different port each time — so settle, then take
    // the one that is actually listening.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final port = controller.boundPort;
    expect(port, isNotNull);

    final invite = BootstrapInvite(
      publicKey: Uint8List(32)..fillRange(0, 32, 9),
      nonce: Uint8List(8),
    );

    // A's bearer starts a contact request...
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/contacts'),
    );
    req.headers.set('Authorization', 'Bearer tok-a');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'target': invite.toUri(), 'greeting': 'hello'}));
    // The error handler is attached NOW, not at the await below: the switch
    // takes the old server down and the connection with it, and a Future that
    // completes with an error nobody is holding yet fails the test on its own.
    final pending = req.close().then<HttpClientResponse?>(
      (r) => r,
      onError: (Object _) => null,
    );

    for (var i = 0; i < 400 && stack.addContactCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      stack.addContactCalls,
      1,
      reason: 'premise: the request is in flight, inside the gap',
    );

    // ...and the app moves to B underneath it.
    (container.read(appControllerProvider.notifier) as _SwitchingAppController)
        .switchTo(
          Identity(nodeId: NodeId.fromHex('22' * 32), displayName: 'B'),
          b,
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    stack.gate.complete();
    // The connection may be cut with the old server; the answer is not what is
    // being tested here.
    await pending.timeout(const Duration(seconds: 5), onTimeout: () => null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      messaging.greeted,
      isEmpty,
      reason: "A's bearer greeted a contact as B, with no bearer for B in it",
    );
  });

  test('every handler that acts is bound to the identity it was built for', () {
    // The behaviour above covers the gap INSIDE a running request. This covers
    // the entry: a callback held by a handler built for A, called at all. It
    // cannot be reached through the socket — `stop()` cuts the connections —
    // so it is asserted where it is decided, and it is what stops the next
    // callback added here from being unbound by omission.
    final source = File('lib/state/api_server.dart').readAsStringSync();
    final start = source.indexOf('final handler = ApiHandler(');
    expect(start, isNot(-1), reason: 'the handler wiring moved');
    final end = source.indexOf('\n    );', start);
    expect(end, isNot(-1));
    // Whitespace-insensitive: `dart format` reflows these argument lists every
    // time one of them grows.
    final wiring = source.substring(start, end).replaceAll(RegExp(r'\s+'), '');

    for (final acting in const [
      'switchIdentity',
      'requestContact',
      'contactAction',
      'send',
      'sendFile',
      'fetchFile',
      'placeCall',
      'callAction',
    ]) {
      final at = wiring.indexOf('$acting:');
      expect(at, isNot(-1), reason: '$acting is no longer wired here');
      expect(
        wiring.substring(at, at + '$acting:'.length + 40),
        contains('moved()'),
        reason: "$acting runs on A's token after the app has moved to B",
      );
    }
    // And the two that keep checking after their first await.
    expect(wiring, contains('_requestContact(target,greeting,moved)'));
    expect(wiring, contains('_sendFile(toHex,path,name,roots,moved)'));
  });
}
