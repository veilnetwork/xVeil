import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/background_node_controller.dart';

class _Transport implements VeilTransport {
  final entered = Completer<void>();
  Completer<void>? gate;
  bool refuse = false;
  int disposals = 0;
  @override
  Future<void> dispose() async {
    disposals++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (refuse) throw StateError('synthetic transport refusal');
  }

  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => const Stream.empty();
  @override
  Stream<int> sessionCount() => const Stream.empty();
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vpn implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Storage extends HiddenVolumeStorage {
  _Storage() : super(({required password, required create}) => null);
  @override
  Future<void> close() async {}
}

class _Node extends EmbeddedNodeController {
  _Node() : super(configPath: '/synthetic', appSocketPath: '/synthetic');
  bool abandoned = false;
  int stops = 0;
  @override
  bool get lastStopWasAbandoned => abandoned;
  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer app;
  late AppController controller;
  late _Transport transport;
  late _Node node;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    app = ProviderContainer(
      overrides: [
        singleSpaceStorageProvider.overrideWithValue(_Storage()),
        backgroundServiceProvider.overrideWithValue(
          BackgroundServiceActions(start: () async {}, stop: () async {}),
        ),
        vpnBackendProvider.overrideWithValue(_Vpn()),
        notificationServiceProvider.overrideWithValue(_Notifications()),
      ],
    );
    controller = app.read(appControllerProvider.notifier);
    await app.read(prefsProvider.future);
    await Future<void>.delayed(Duration.zero);
    transport = _Transport();
    node = _Node();
    app.read(realStackProvider.notifier).state = RealVeilStack.overParts(
      controller: node,
      transport: transport,
      myInvite: BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8)),
    );
  });
  tearDown(() => app.dispose());

  test('a second lock joins the unpublished original stack disposal', () {
    fakeAsync((clock) {
      final gate = transport.gate = Completer<void>();
      var firstDone = false, secondDone = false;
      unawaited(controller.lock().then((_) => firstDone = true));
      clock.flushMicrotasks();
      expect(transport.entered.isCompleted, isTrue);
      expect(app.read(realStackProvider), isNull);
      unawaited(controller.lock().then((_) => secondDone = true));
      clock.flushMicrotasks();
      expect(firstDone, isFalse);
      expect(
        secondDone,
        isFalse,
        reason: 'no gate-free second lock may overtake an accepted disposer',
      );
      expect(transport.disposals, 1);
      gate.complete();
      clock.flushMicrotasks();
      expect(firstDone, isTrue);
      expect(secondDone, isTrue);
      expect(controller.lastTeardown.complete, isTrue);
      expect(node.stops, 1);
    });
  });

  test('a failed stack stop remains unconfirmed on the next lock', () async {
    transport.refuse = true;
    await expectLater(controller.lock(), throwsStateError);
    expect(controller.lastTeardown.complete, isFalse);
    await expectLater(controller.lock(), throwsStateError);
    expect(controller.lastTeardown.complete, isFalse);
    expect(transport.disposals, 1);
    expect(node.stops, 1, reason: 'independent cleanup still stops the node');
  });

  test(
    'native stop abandonment remains visible after the provider is empty',
    () async {
      node.abandoned = true;
      await expectLater(controller.lock(), throwsStateError);
      expect(controller.lastTeardown.incomplete, contains('node'));
      // A controller reports its last stop, not every historical detached stop.
      // Later state must never authorize this original disposal retroactively.
      node.abandoned = false;
      await expectLater(controller.lock(), throwsStateError);
      expect(controller.lastTeardown.incomplete, contains('node'));
      expect(
        node.stops,
        1,
        reason: 'a consumed native handle cannot be retried',
      );
    },
  );
}
