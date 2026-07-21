import 'dart:convert';

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
const _fallback =
    'bb11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddff';
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
  Map<String, String> receivedApplicationProxyListens = const {};

  @override
  Future<VpnBackendState> probe() async => probeResult;

  @override
  Future<VpnBackendState> status() async => probeResult;

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    Map<String, String> applicationProxyListens = const {},
    String? obfs4Psk,
  }) async {
    starts++;
    receivedPolicy = policy;
    receivedListen = socks5Listen;
    receivedExitNodeId = exitNodeId;
    receivedObfs4Psk = obfs4Psk;
    receivedApplicationProxyListens = applicationProxyListens;
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
      vpnTransportPreflightProvider.overrideWithValue((_) async {}),
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

Future<void> _configureExit(
  ProviderContainer container, {
  bool manualSocks = false,
}) async {
  await container
      .read(proxyRoutingProvider.notifier)
      .set(ProxyRouting(socks5Enabled: manualSocks, exitNodeId: _exit));
}

void main() {
  test(
    'starts its own SOCKS transport without enabling manual SOCKS',
    () async {
      final backend = _FakeBackend();
      final container = await _container(backend);
      await _configureExit(container);

      await container.read(vpnControllerProvider.notifier).start();

      final state = container.read(vpnControllerProvider);
      expect(state.isRunning, isTrue);
      expect(state.policy.enabled, isTrue);
      expect(container.read(proxyRoutingProvider).socks5Enabled, isFalse);
      expect(container.read(vpnProxyDemandProvider), isTrue);
      expect(container.read(effectiveProxyRoutingProvider).isActive, isTrue);
      expect(container.read(vpnProxyProfilesProvider), hasLength(1));
      expect(backend.starts, 1);
      expect(backend.receivedListen, ProxyRouting.defaultListen);
      expect(backend.receivedExitNodeId, _exit);
      expect(backend.receivedObfs4Psk, _psk);
    },
  );

  test(
    'restores a running native tunnel only after oproxy prefs load',
    () async {
      final backend = _FakeBackend()
        ..probeResult = const VpnBackendState(VpnBackendPhase.running);
      SharedPreferences.setMockInitialValues({
        'proxy_routing': jsonEncode(
          const ProxyRouting(exitNodeId: _exit).toJson(),
        ),
        'vpn_routing_policy': jsonEncode(
          const VpnRoutingPolicy(enabled: true).toJson(),
        ),
      });
      final container = ProviderContainer(
        overrides: [
          vpnBackendProvider.overrideWithValue(backend),
          deniableBootProvider.overrideWithValue(
            const DeniableBootConfig(
              runtimeDir: '/tmp/xveil-test',
              obfs4Psk: _psk,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(vpnControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(container.read(vpnControllerProvider).isRunning, isTrue);
      expect(container.read(vpnProxyDemandProvider), isTrue);
      expect(container.read(vpnProxyProfilesProvider), hasLength(1));
      expect(backend.stops, 0);
    },
  );

  test(
    'passes per-application oproxy listeners to the native backend',
    () async {
      final backend = _FakeBackend();
      final container = await _container(backend);
      await container
          .read(proxyRoutingProvider.notifier)
          .set(
            const ProxyRouting(
              oProxies: [
                OproxyEndpoint(nodeId: _exit, label: 'Primary'),
                OproxyEndpoint(nodeId: _fallback, label: 'Fallback'),
              ],
              defaultOproxyNodeIds: [_exit, _fallback],
            ),
          );
      await container
          .read(vpnControllerProvider.notifier)
          .configure(
            const VpnRoutingPolicy(
              vpnOproxyNodeIds: [_exit, _fallback],
              applicationOproxyNodeIds: {
                'org.mozilla.firefox': [_fallback, _exit],
              },
            ),
          );

      await container.read(vpnControllerProvider.notifier).start();

      expect(backend.starts, 1);
      expect(container.read(vpnProxyProfilesProvider), hasLength(2));
      expect(
        backend.receivedApplicationProxyListens['org.mozilla.firefox'],
        '127.0.0.1:1081',
      );
    },
  );

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

  test('unreachable exit never installs the native system tunnel', () async {
    final backend = _FakeBackend();
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        vpnBackendProvider.overrideWithValue(backend),
        vpnTransportPreflightProvider.overrideWithValue(
          (_) async => throw StateError('exit is offline'),
        ),
        deniableBootProvider.overrideWithValue(
          const DeniableBootConfig(
            runtimeDir: '/tmp/xveil-test',
            obfs4Psk: _psk,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(vpnControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await _configureExit(container);

    await container.read(vpnControllerProvider.notifier).start();

    expect(backend.starts, 0);
    expect(container.read(vpnControllerProvider).isRunning, isFalse);
    expect(container.read(vpnControllerProvider).policy.enabled, isFalse);
    expect(container.read(vpnProxyDemandProvider), isFalse);
    expect(
      container.read(vpnControllerProvider).backend.detail,
      contains('system tunnel was not enabled'),
    );
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
      await _configureExit(container);

      await container.read(vpnControllerProvider.notifier).start();

      expect(container.read(vpnControllerProvider).isRunning, isFalse);
      expect(container.read(vpnControllerProvider).policy.enabled, isFalse);
      expect(container.read(vpnProxyDemandProvider), isFalse);
      expect(container.read(proxyRoutingProvider).socks5Enabled, isFalse);
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
      await _configureExit(container);
      await container.read(vpnControllerProvider.notifier).start();

      await container.read(vpnControllerProvider.notifier).stop();

      expect(backend.stops, 1);
      expect(container.read(vpnControllerProvider).policy.enabled, isTrue);
      expect(
        container.read(vpnControllerProvider).backend.phase,
        VpnBackendPhase.error,
      );
      expect(container.read(vpnProxyDemandProvider), isTrue);
    },
  );

  test('successful stop releases only the VPN-owned SOCKS transport', () async {
    final backend = _FakeBackend();
    final container = await _container(backend);
    await _configureExit(container);
    await container.read(vpnControllerProvider.notifier).start();

    await container.read(vpnControllerProvider.notifier).stop();

    expect(container.read(vpnProxyDemandProvider), isFalse);
    expect(container.read(proxyRoutingProvider).socks5Enabled, isFalse);
    expect(container.read(effectiveProxyRoutingProvider).socks5Active, isFalse);
  });

  test('successful stop preserves a manually enabled SOCKS listener', () async {
    final backend = _FakeBackend();
    final container = await _container(backend);
    await _configureExit(container, manualSocks: true);
    await container.read(vpnControllerProvider.notifier).start();

    await container.read(vpnControllerProvider.notifier).stop();

    expect(container.read(vpnProxyDemandProvider), isFalse);
    expect(container.read(proxyRoutingProvider).socks5Enabled, isTrue);
    expect(container.read(effectiveProxyRoutingProvider).socks5Active, isTrue);
  });

  test('unsupported backend is fail-closed and is never invoked', () async {
    final backend = _FakeBackend()
      ..probeResult = const VpnBackendState(VpnBackendPhase.unsupported);
    final container = await _container(backend);
    await _configureExit(container);

    await container.read(vpnControllerProvider.notifier).start();

    expect(backend.starts, 0);
    expect(container.read(vpnControllerProvider).isRunning, isFalse);
  });
}
