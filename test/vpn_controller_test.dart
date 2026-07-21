import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/state/proxy_routing_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vpn_controller.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';
const _psk = 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=';

class _FakeBackend implements VpnBackend {
  VpnBackendState probeResult = const VpnBackendState(VpnBackendPhase.stopped);
  VpnBackendState startResult = const VpnBackendState(VpnBackendPhase.running);
  VpnBackendState stopResult = const VpnBackendState(VpnBackendPhase.stopped);
  int starts = 0;
  int stops = 0;
  VpnRoutingPolicy? receivedPolicy;
  String? receivedListen;
  String? receivedExitNodeId;
  String? receivedObfs4Psk;

  @override
  Future<VpnBackendState> probe() async => probeResult;

  @override
  Future<VpnBackendState> status() async => probeResult;

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    String? obfs4Psk,
  }) async {
    starts++;
    receivedPolicy = policy;
    receivedListen = socks5Listen;
    receivedExitNodeId = exitNodeId;
    receivedObfs4Psk = obfs4Psk;
    return startResult;
  }

  @override
  Future<VpnBackendState> stop() async {
    stops++;
    return stopResult;
  }
}

Future<ProviderContainer> _container(_FakeBackend backend) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      vpnBackendProvider.overrideWithValue(backend),
      deniableBootProvider.overrideWithValue(
        const DeniableBootConfig(runtimeDir: '/tmp/xveil-test', obfs4Psk: _psk),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(vpnControllerProvider);
  await Future<void>.delayed(Duration.zero);
  return container;
}

Future<void> _enableProxy(ProviderContainer container) async {
  await container
      .read(proxyRoutingProvider.notifier)
      .set(const ProxyRouting(socks5Enabled: true, exitNodeId: _exit));
}

void main() {
  test('starts only after backend confirms forwarding', () async {
    final backend = _FakeBackend();
    final container = await _container(backend);
    await _enableProxy(container);

    await container.read(vpnControllerProvider.notifier).start();

    final state = container.read(vpnControllerProvider);
    expect(state.isRunning, isTrue);
    expect(state.policy.enabled, isTrue);
    expect(backend.starts, 1);
    expect(backend.receivedListen, ProxyRouting.defaultListen);
    expect(backend.receivedExitNodeId, _exit);
    expect(backend.receivedObfs4Psk, _psk);
  });

  test('does not call native backend without a working SOCKS5 exit', () async {
    final backend = _FakeBackend();
    final container = await _container(backend);

    await container.read(vpnControllerProvider.notifier).start();

    expect(backend.starts, 0);
    expect(
      container.read(vpnControllerProvider).backend.phase,
      VpnBackendPhase.error,
    );
    expect(container.read(vpnControllerProvider).policy.enabled, isFalse);
  });

  test(
    'native start error never persists an optimistic enabled state',
    () async {
      final backend = _FakeBackend()
        ..startResult = const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'permission denied',
        );
      final container = await _container(backend);
      await _enableProxy(container);

      await container.read(vpnControllerProvider.notifier).start();

      expect(container.read(vpnControllerProvider).isRunning, isFalse);
      expect(container.read(vpnControllerProvider).policy.enabled, isFalse);
    },
  );

  test(
    'failed native stop keeps enabled intent and reports the error',
    () async {
      final backend = _FakeBackend()
        ..stopResult = const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'still running',
        );
      final container = await _container(backend);
      await _enableProxy(container);
      await container.read(vpnControllerProvider.notifier).start();

      await container.read(vpnControllerProvider.notifier).stop();

      expect(backend.stops, 1);
      expect(container.read(vpnControllerProvider).policy.enabled, isTrue);
      expect(
        container.read(vpnControllerProvider).backend.phase,
        VpnBackendPhase.error,
      );
    },
  );

  test('unsupported backend is fail-closed and is never invoked', () async {
    final backend = _FakeBackend()
      ..probeResult = const VpnBackendState(VpnBackendPhase.unsupported);
    final container = await _container(backend);
    await _enableProxy(container);

    await container.read(vpnControllerProvider.notifier).start();

    expect(backend.starts, 0);
    expect(container.read(vpnControllerProvider).isRunning, isFalse);
  });
}
