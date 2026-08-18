import 'dart:async';
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
  List<String> receivedExitNodeIds = const [];
  String? receivedObfs4Psk;
  Map<String, String> receivedApplicationProxyListens = const {};

  /// Holds [start] open where the real native start takes seconds, so a lock
  /// can land INSIDE the start window without a timing race.
  Completer<void>? startBarrier;

  @override
  Future<VpnBackendState> probe() async => probeResult;

  @override
  Future<VpnBackendState> status() async => probeResult;

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    List<String> exitNodeIds = const [],
    Map<String, String> applicationProxyListens = const {},
    String? obfs4Psk,
  }) async {
    starts++;
    receivedPolicy = policy;
    receivedListen = socks5Listen;
    receivedExitNodeId = exitNodeId;
    receivedExitNodeIds = exitNodeIds;
    receivedObfs4Psk = obfs4Psk;
    receivedApplicationProxyListens = applicationProxyListens;
    final barrier = startBarrier;
    if (barrier != null) await barrier.future;
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
      expect(backend.receivedExitNodeIds, [_exit]);
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
      expect(backend.receivedExitNodeIds, [_exit, _fallback]);
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

  test(
    'a teardown during a start never leaves the tunnel up (audit XV-H2)',
    () async {
      final backend = _FakeBackend()..startBarrier = Completer<void>();
      final container = await _container(backend);
      await _configureExit(container);
      final controller = container.read(vpnControllerProvider.notifier);

      final starting = controller.start();
      for (var pump = 0; pump < 10; pump++) {
        await Future<void>.delayed(Duration.zero);
      }
      // The start is inside the native call, which is where a lock lands in
      // practice: busy, and `starting` — so NOT running.
      expect(backend.starts, 1, reason: 'the start must be in flight');
      expect(container.read(vpnControllerProvider).busy, isTrue);
      expect(
        container.read(vpnControllerProvider).backend.phase,
        VpnBackendPhase.starting,
      );

      // The lock. It ends the generation synchronously and then waits for the
      // start it interrupted, so the barrier is released before it is awaited.
      final teardown = controller.stopForTeardown();
      backend.startBarrier!.complete();
      await starting;
      final phase = await teardown;

      expect(phase, VpnBackendPhase.stopped);
      expect(backend.stops, greaterThanOrEqualTo(1));
      final state = container.read(vpnControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.policy.enabled, isFalse);
      expect(container.read(vpnProxyDemandProvider), isFalse);
      // The persisted flag is what a later launch restores from, so an
      // interrupted start must not leave it saying the VPN was on.
      final prefs = await container.read(prefsProvider.future);
      expect(
        VpnRoutingPolicy.fromJson(
          jsonDecode(prefs.getString('vpn_routing_policy') ?? '{}')
              as Map<String, dynamic>,
        ).enabled,
        isFalse,
      );
    },
  );

  test(
    'a second start does not erase the record of the first (audit X13-M9)',
    () async {
      // The tap that arrives while the tunnel is coming up. `_start`'s opening
      // guard refuses it, so it is OVER before `start` returns — and the record
      // a teardown waits on used to be overwritten with that finished future.
      // The lock then asked the backend to stop with the native start still
      // inside its call, and answered `stopped` for a tunnel that had not come
      // up yet.
      final backend = _FakeBackend()..startBarrier = Completer<void>();
      final container = await _container(backend);
      await _configureExit(container);
      final controller = container.read(vpnControllerProvider.notifier);

      final first = controller.start();
      for (var pump = 0; pump < 10; pump++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backend.starts, 1, reason: 'the first start must be in flight');

      await controller.start();
      expect(
        backend.starts,
        1,
        reason: 'the second start is refused while the first is busy',
      );

      final teardown = controller.stopForTeardown();
      for (var pump = 0; pump < 10; pump++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        backend.stops,
        0,
        reason:
            'the teardown asked the backend to stop while the native start '
            'it exists to cancel was still inside the call',
      );

      backend.startBarrier!.complete();
      await first;
      final phase = await teardown;

      expect(phase, VpnBackendPhase.stopped);
      expect(backend.stops, greaterThanOrEqualTo(1));
      final state = container.read(vpnControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.policy.enabled, isFalse);
    },
  );

  test(
    'a teardown that is the first read of the provider still stops the tunnel',
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

      // The FIRST touch of the provider in this container is the teardown
      // itself — a lock in a session that never opened the VPN screen. Building
      // the controller schedules the restore that adopts a live tunnel, so the
      // lock must not be defeated by the state it just constructed.
      final phase = await container
          .read(vpnControllerProvider.notifier)
          .stopForTeardown();
      // Well past the restore: prefs, the routing load and the native probe.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(phase, VpnBackendPhase.stopped);
      expect(backend.stops, 1);
      expect(container.read(vpnControllerProvider).isRunning, isFalse);
      expect(container.read(vpnProxyDemandProvider), isFalse);
      expect(container.read(vpnProxyProfilesProvider), isEmpty);
    },
  );

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
