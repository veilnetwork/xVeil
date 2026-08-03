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
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/providers.dart';

// Audit XV-10, second half: an upgraded `/v1/events` socket carried no trace
// of the token that authorised it, and `HttpServer.close(force: true)` does
// not take upgraded WebSockets down. So a live feed survived every way there
// is of withdrawing it — revoking the token, switching the API off, and moving
// to another identity.
//
// The third is the one that matters most here. This app's whole proposition is
// that identities are separable; a subscriber authorised under one staying
// attached while the app moves to another is an events leak ACROSS the
// boundary the product exists to keep.
//
// Driven through the real controller rather than the socket class, because the
// question is not whether `stop()` closes sockets — that is covered next door
// — but whether each of these three actions actually reaches it.

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

Future<HiddenVolumeStorage> _storageWithTokens(
  List<(String id, String secret)> tokens,
) async {
  final log = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) => log,
  );
  expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
  await storage.putSetting(
    'api.tokens',
    jsonEncode([
      for (final (id, secret) in tokens)
        {'id': id, 'name': id, 'token': secret, 'ro': false},
    ]),
  );
  await storage.putSetting('api.enabled', '1');
  return storage;
}

void main() {
  late ProviderContainer container;
  late ApiServerController controller;

  Future<ApiServerController> boot(HiddenVolumeStorage storage) async {
    _activeStorage = storage;
    _initialIdentity = Identity(
      nodeId: NodeId.fromHex('11' * 32),
      displayName: 'A',
    );
    container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_SwitchingAppController.new),
        storageProvider.overrideWith((ref) => _activeStorage),
        groupServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container.read(apiServerControllerProvider);
    final ctrl = container.read(apiServerControllerProvider.notifier);
    for (var i = 0; i < 400 && ctrl.boundPort == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ctrl.boundPort, isNotNull, reason: 'the API never came up');
    return controller = ctrl;
  }

  /// Subscribe to the live feed and return the socket plus a future that
  /// completes when the server lets it go.
  Future<(WebSocket, Future<void>)> subscribe(String secret) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${controller.boundPort}/v1/events?token=$secret',
    );
    final gone = Completer<void>();
    ws.listen((_) {}, onDone: gone.complete, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (ws, gone.future);
  }

  setUp(() => ApiServerController.debugBindPort = 0);
  tearDown(() => ApiServerController.debugBindPort = kApiPort);

  test('revoking a token disconnects the feed it opened', () async {
    final storage = await _storageWithTokens([('id-a', 'tok-a')]);
    addTearDown(storage.close);
    await boot(storage);
    final (ws, gone) = await subscribe('tok-a');
    expect(controller.liveSocketCount, 1);

    await controller.revokeToken('id-a');

    await gone.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the revoked client kept its live feed — "revoked" meant only that '
        'the next REQUEST would be refused',
      ),
    );
    expect(ws.closeCode, 1008, reason: 'the client is told why, not just cut');
  });

  test('a revoke is attributed to its token, not applied to everyone',
      () async {
    // The revoked socket is closed BY TOKEN — 1008, "token revoked" — which
    // is the whole point of binding a socket to the token that opened it.
    //
    // The others come down too, with a different code, and that is honest
    // rather than accidental: the handler holds an immutable snapshot of the
    // token list, so changing it restarts the server, and 1001 is what a
    // restart looks like. The two codes are what tells the targeted close
    // apart from the blanket one — without the registry, bot-a would have got
    // 1001 like everybody else, or (before this fix) nothing at all.
    final storage = await _storageWithTokens([
      ('id-a', 'tok-a'),
      ('id-b', 'tok-b'),
    ]);
    addTearDown(storage.close);
    await boot(storage);
    final (wsA, goneA) = await subscribe('tok-a');
    final (wsB, goneB) = await subscribe('tok-b');
    expect(controller.liveSocketCount, 2);

    await controller.revokeToken('id-a');
    await goneA.timeout(const Duration(seconds: 5));
    await goneB.timeout(const Duration(seconds: 5));

    expect(wsA.closeCode, 1008, reason: 'revoked, and told so');
    expect(
      wsB.closeCode, 1001,
      reason: 'bot-b was not revoked — it was carried out by the restart, '
          'which is a reconnect rather than a refusal',
    );
  });

  test('turning the API off disconnects live feeds', () async {
    final storage = await _storageWithTokens([('id-a', 'tok-a')]);
    addTearDown(storage.close);
    await boot(storage);
    final (_, gone) = await subscribe('tok-a');
    expect(controller.liveSocketCount, 1);

    await controller.disable();

    await gone.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the API was off and a client was still on its event feed',
      ),
    );
    expect(controller.running, isFalse);
    expect(controller.liveSocketCount, 0);
  });

  test('switching identity disconnects the previous identity\'s feed',
      () async {
    // THE ONE THAT MATTERS. A subscriber authorised under identity A stayed
    // attached across the move to identity B — a live events channel spanning
    // the separation this app is for.
    final first = await _storageWithTokens([('id-a', 'tok-a')]);
    final second = await _storageWithTokens([('id-b', 'tok-b')]);
    addTearDown(first.close);
    addTearDown(second.close);
    await boot(first);
    final (ws, gone) = await subscribe('tok-a');
    expect(controller.liveSocketCount, 1);

    (container.read(appControllerProvider.notifier) as _SwitchingAppController)
        .expose(
      Identity(nodeId: NodeId.fromHex('22' * 32), displayName: 'B'),
      second,
    );

    await gone.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        "identity A's event feed outlived the switch to identity B",
      ),
    );
    expect(ws.closeCode, isNotNull);

    // …and the new identity does get its own server, so the teardown is a
    // handover rather than simply breaking the API.
    for (var i = 0; i < 400; i++) {
      final tokens = container.read(apiServerControllerProvider).tokens;
      if (tokens.any((t) => t.token == 'tok-b')) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      container.read(apiServerControllerProvider).tokens.single.token,
      'tok-b',
    );
    // The old secret is not accepted by the new identity's server.
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:${controller.boundPort}/v1/events?token=tok-a',
      ),
      throwsA(isA<WebSocketException>()),
    );
  });
}
