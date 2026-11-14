import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/data/vpn/windows_process_probe.dart';
import 'package:xveil/data/vpn/windows_managed_vpn_backend.dart';

class _Probe extends WindowsProcessProbe {
  _Probe(this.state);
  WindowsProcessState state;
  @override
  WindowsProcessState read(int pid) => state;
}

/// Immediate immutable OS observations make the queue boundary deterministic:
/// an event turn drains their ready microtasks, with no filesystem time limit.
class _ImmediateStatusFile implements File {
  _ImmediateStatusFile(this.contents);
  final String contents;
  int reads = 0;
  @override
  Future<bool> exists() => Future.value(true);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    reads++;
    return Future.value(contents);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory fixture, session;
  late File status;
  const token = 'synthetic session token';
  Future<void> publish(String phase, {String value = token}) =>
      status.writeAsString(jsonEncode({'token': value, 'phase': phase}));
  WindowsManagedVpnBackend backend(
    WindowsProcessState observed, {
    Duration timeout = const Duration(seconds: 10),
  }) => WindowsManagedVpnBackend.withSessionForTesting(
    directory: session,
    statusFile: status,
    token: token,
    helperPid: 77,
    processProbe: _Probe(observed),
    requestStop: () async {},
    stopTimeout: timeout,
  );
  setUp(() {
    fixture = Directory.systemTemp.createTempSync(
      'xveil-windows-vpn-lifetime-',
    );
    session = Directory('${fixture.path}/request')..createSync();
    File('${session.path}/request.json').writeAsStringSync('synthetic request');
    status = File('${fixture.path}/protected-status.json');
  });
  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  test(
    'failed process observation must preserve a running helper owner',
    () async {
      await publish('running');
      final value = backend(WindowsProcessState.unknown);
      expect((await value.status()).phase, VpnBackendPhase.running);
      expect(session.existsSync(), isTrue);
      await publish('stopped');
      expect((await value.stop()).phase, VpnBackendPhase.stopped);
      expect(session.existsSync(), isFalse);
    },
  );

  test(
    'unverified status cannot retire the session or make a later stop a no-op',
    () async {
      await publish('stopped', value: 'wrong token');
      var controls = 0;
      final value = WindowsManagedVpnBackend.withSessionForTesting(
        directory: session,
        statusFile: status,
        token: token,
        helperPid: 77,
        processProbe: _Probe(WindowsProcessState.running),
        requestStop: () async => controls++,
      );
      expect((await value.status()).phase, VpnBackendPhase.error);
      expect(session.existsSync(), isTrue);
      await publish('stopped');
      expect((await value.stop()).phase, VpnBackendPhase.stopped);
      expect(controls, 1);
      expect(session.existsSync(), isFalse);
    },
  );

  test(
    'confirmed helper exit completes stop after its terminal file vanished',
    () async {
      final value = backend(WindowsProcessState.exited, timeout: Duration.zero);
      expect(status.existsSync(), isFalse);
      expect((await value.stop()).phase, VpnBackendPhase.stopped);
      expect(session.existsSync(), isFalse);
    },
  );
  test(
    'concurrent status cannot retire a session during accepted stop control',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final native = _ImmediateStatusFile(
        jsonEncode({'token': token, 'phase': 'stopped'}),
      );
      final value = WindowsManagedVpnBackend.withSessionForTesting(
        directory: session,
        statusFile: native,
        token: token,
        helperPid: 77,
        processProbe: _Probe(WindowsProcessState.unknown),
        stopTimeout: Duration.zero,
        requestStop: () async {
          entered.complete();
          await release.future;
        },
      );
      final stop = value.stop();
      await entered.future;
      final observation = value.status();
      try {
        await Future<void>(() {});
        expect(
          native.reads,
          0,
          reason: 'accepted stop still owns this session',
        );
      } finally {
        release.complete();
        await Future.wait([stop, observation]);
      }
      expect((await stop).phase, VpnBackendPhase.stopped);
      expect((await observation).phase, VpnBackendPhase.stopped);
      expect(session.existsSync(), isFalse);
    },
  );
  test('concurrent stops share accepted control and one release', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var controls = 0;
    await publish('stopped');
    final value = WindowsManagedVpnBackend.withSessionForTesting(
      directory: session,
      statusFile: status,
      token: token,
      helperPid: 77,
      processProbe: _Probe(WindowsProcessState.running),
      stopTimeout: Duration.zero,
      requestStop: () async {
        controls++;
        entered.complete();
        await release.future;
      },
    );
    final first = value.stop();
    await entered.future;
    final second = value.stop();
    try {
      expect(identical(first, second), isTrue);
    } finally {
      release.complete();
      await Future.wait([first, second]);
    }
    expect(controls, 1);
    expect((await second).phase, VpnBackendPhase.stopped);
  });

  test('a start between stops prevents sharing the earlier stop', () async {
    final entered = Completer<void>(), release = Completer<void>();
    await publish('stopped');
    final value = WindowsManagedVpnBackend.withSessionForTesting(
      directory: session,
      statusFile: status,
      token: token,
      helperPid: 77,
      processProbe: _Probe(WindowsProcessState.running),
      stopTimeout: Duration.zero,
      requestStop: () async {
        entered.complete();
        await release.future;
      },
    );
    final first = value.stop();
    await entered.future;
    final start = value.start(
      policy: const VpnRoutingPolicy(),
      socks5Listen: '127.0.0.1:1080',
      exitNodeId: '00' * 32,
      applicationProxyListens: const {'org.example.app': '127.0.0.1:1080'},
    );
    final second = value.stop();
    try {
      expect(identical(first, second), isFalse);
    } finally {
      release.complete();
      await Future.wait([first, start, second]);
    }
    expect((await start).phase, VpnBackendPhase.error);
    expect((await second).phase, VpnBackendPhase.stopped);
  });

  for (final state in [
    WindowsProcessState.running,
    WindowsProcessState.unknown,
  ]) {
    test(
      'stop timeout with $state keeps the control owner for retry',
      () async {
        await publish('running');
        final value = backend(state, timeout: Duration.zero);
        expect((await value.stop()).phase, VpnBackendPhase.error);
        expect(session.existsSync(), isTrue);
        await publish('stopped');
        expect((await value.stop()).phase, VpnBackendPhase.stopped);
        expect(session.existsSync(), isFalse);
      },
    );
  }
  for (final phase in [null, 17, 'future-state']) {
    test(
      'malformed phase $phase cannot become authenticated terminal success',
      () async {
        await status.writeAsString(
          jsonEncode({'token': token, 'phase': phase}),
        );
        final value = backend(
          WindowsProcessState.running,
          timeout: Duration.zero,
        );
        expect((await value.status()).phase, VpnBackendPhase.error);
        expect((await value.stop()).phase, VpnBackendPhase.error);
        expect(session.existsSync(), isTrue);
        await publish('stopped');
        expect((await value.stop()).phase, VpnBackendPhase.stopped);
        expect(session.existsSync(), isFalse);
      },
    );
  }
  test('unreadable status bytes preserve the live control session', () async {
    await status.writeAsString('{');
    final value = backend(WindowsProcessState.unknown, timeout: Duration.zero);
    expect((await value.stop()).phase, VpnBackendPhase.error);
    expect(session.existsSync(), isTrue);
    await publish('stopped');
    expect((await value.stop()).phase, VpnBackendPhase.stopped);
  });
  test(
    'invalid detail type is refused without a raw cast error or retirement',
    () async {
      await status.writeAsString(
        jsonEncode({'token': token, 'phase': 'stopped', 'detail': 1}),
      );
      final value = backend(
        WindowsProcessState.running,
        timeout: Duration.zero,
      );
      expect((await value.status()).phase, VpnBackendPhase.error);
      expect(session.existsSync(), isTrue);
      expect((await value.stop()).phase, VpnBackendPhase.error);
      await publish('stopped');
      expect((await value.stop()).phase, VpnBackendPhase.stopped);
    },
  );
  test(
    'a queued start owns the original application-routing request',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      await publish('stopped');
      final value = WindowsManagedVpnBackend.withSessionForTesting(
        directory: session,
        statusFile: status,
        token: token,
        helperPid: 77,
        processProbe: _Probe(WindowsProcessState.running),
        stopTimeout: Duration.zero,
        requestStop: () async {
          entered.complete();
          await release.future;
        },
      );
      final stop = value.stop();
      await entered.future;
      final applications = {'org.example.app': '127.0.0.1:1080'};
      final start = value.start(
        policy: const VpnRoutingPolicy(),
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: '00' * 32,
        applicationProxyListens: applications,
      );
      applications.clear();
      release.complete();
      await stop;
      final result = await start;
      expect(result.phase, VpnBackendPhase.error);
      expect(result.detail, contains('Per-application oproxy'));
    },
  );
}
