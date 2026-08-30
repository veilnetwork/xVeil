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
import 'dart:math';
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
  Future<bool> sendRequest(NodeId peer, [String? greeting]) async {
    greeted.add(peer);
    // Deposited, so the caller does not report a failure this fake never had.
    return true;
  }

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

  test('every handler that reaches live state is bound to its identity', () {
    // The behaviour above covers the gap INSIDE a running request. This covers
    // the entry: a callback held by a handler built for A, called at all. It
    // cannot be reached through the socket — `stop()` cuts the connections —
    // so it is asserted where it is decided.
    //
    // DERIVED, not enumerated. This check used to name eight callbacks, and a
    // ninth — `setWebhook` — was added unbound and the list said nothing,
    // because a list is a record of what somebody remembered. The rule instead
    // reads every entry in the wiring and asks a question of it: does this
    // expression reach something that OUTLIVES the identity the handler was
    // built for — `ref.read(...)`, the controller's own `state`, or one of its
    // private members? Those must consult `moved()`. Entries that delegate to
    // an object captured for this identity (`groupApi`, `cloudApi`,
    // `groupService`) are bound by construction and need nothing.
    final source = File('lib/state/api_server.dart').readAsStringSync();
    final start = source.indexOf('final handler = ApiHandler(');
    expect(start, isNot(-1), reason: 'the handler wiring moved');
    final body = _balanced(source, source.indexOf('(', start));
    expect(body, isNotNull, reason: 'the handler wiring is unbalanced');

    // Every method declared on this class, so a bare `name: method` reference
    // can be recognised for what it reaches. Nested generics included:
    // `Future<List<String>> lockForApi()` is exactly the shape a lazier
    // pattern misses, and it is one of the entries this rule has to see.
    final members = RegExp(
      r'^  [\w<>,?\s]+?\s+([A-Za-z_]\w*)\s*\(',
      multiLine: true,
    ).allMatches(source).map((m) => m.group(1)!).toSet();
    expect(
      members.length,
      greaterThan(20),
      reason:
          'only ${members.length} methods parsed out of the controller — '
          'the bare-reference test below would see almost nothing',
    );

    final entries = _entries(body!);
    // Vacuity guard: everything below passes on an empty parse.
    expect(
      entries.length,
      greaterThan(80),
      reason:
          'only ${entries.length} handler entries parsed — the rule below '
          'would pass without checking anything',
    );

    // Deliberately unbound, each with the reason. A list of names would be a
    // record of what somebody remembered; a reason is a decision, and the
    // next entry added here has to make one.
    const unboundOnPurpose = <String, String>{
      'tokens':
          'the capture that IS the binding — read once, here, and what keeps '
          'authenticating A after the app has moved on',
      'lockAccount':
          'closing the boundary is not identity-scoped: a caller asking to '
          'lock is asking for the session to end, and refusing would leave it '
          'open',
    };

    final unbound = <String>[];
    var guarded = 0;
    for (final entry in entries.entries) {
      // Collapsed to single spaces, NOT removed: stripping whitespace glues
      // `await _contacts()` into `await_contacts()`, and the private-member
      // test below then stops seeing a private member at all. That mistake
      // made this rule report five guarded entries instead of twenty-one, and
      // an emptier list is exactly how a structural check goes quiet.
      final flat = entry.value.replaceAll(RegExp(r'\s+'), ' ');
      // A bare reference to a method of this class reaches live state through
      // the method BODY, where none of the markers below appear. That is how
      // `setWebhook: setWebhook` looked innocent to the first version of this
      // rule while being the one entry that was actually unbound.
      final bare =
          RegExp(r'^[A-Za-z_]\w*$').hasMatch(flat.trim()) &&
          members.contains(flat.trim());
      final reachesLive =
          bare ||
          flat.contains('ref.read(') ||
          flat.contains('state.') ||
          RegExp(r'(^|[^A-Za-z0-9_.])_[A-Za-z]').hasMatch(flat);
      if (!reachesLive) continue;
      if (flat.contains('moved()')) {
        guarded++;
        continue;
      }
      if (unboundOnPurpose.containsKey(entry.key)) continue;
      unbound.add('${entry.key}: ${flat.substring(0, min(70, flat.length))}');
    }

    expect(
      guarded,
      greaterThan(15),
      reason:
          'only $guarded guarded entries found — the detection above has '
          'stopped recognising the wiring',
    );
    expect(
      unbound,
      isEmpty,
      reason:
          'these run on A\'s token after the app has moved to B. Either make '
          'them consult moved(), or — if the value is captured for this '
          'identity on purpose — say so, with a reason, in '
          'unboundOnPurpose:\n  ${unbound.join('\n  ')}',
    );

    // And the two that keep checking after their first await.
    final wiring = body.replaceAll(RegExp(r'\s+'), '');
    expect(wiring, contains('_requestContact(target,greeting,moved)'));
    expect(wiring, contains('_sendFile(toHex,path,name,roots,moved)'));
    expect(
      wiring,
      contains('setWebhook(url,moved)'),
      reason:
          'setWebhook writes to storage before it publishes; a switch '
          'landing in that gap pointed B\'s event feed at A\'s URL',
    );
  });
}

/// The text inside the brackets that open at [at], brackets balanced.
String? _balanced(String source, int at) {
  var depth = 0;
  for (var i = at; i < source.length; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return source.substring(at + 1, i);
    }
  }
  return null;
}

/// `name: expression` pairs at the top level of an argument list.
///
/// Split on top-level commas rather than by line: `dart format` reflows these
/// arguments every time one of them grows, and half of them are conditionals
/// spanning several lines.
Map<String, String> _entries(String body) {
  final withoutComments = body.replaceAll(RegExp('//[^\n]*'), '');
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final c in withoutComments.split('')) {
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      parts.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  if (buffer.toString().trim().isNotEmpty) parts.add(buffer.toString());

  final out = <String, String>{};
  for (final part in parts) {
    final match = RegExp(r'^\s*([A-Za-z_]\w*)\s*:').firstMatch(part);
    if (match == null) continue;
    out[match.group(1)!] = part.substring(match.end);
  }
  return out;
}
