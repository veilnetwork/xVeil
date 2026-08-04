@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/vpn/linux_managed_vpn_backend.dart';
import 'package:xveil/data/vpn/privileged_launch_guard.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';

/// The elevation itself, driven end to end against a stand-in `pkexec`.
///
/// Two things the guard's own tests cannot show, because they stop at the
/// verdict:
///
///   * the verdict is taken AGAIN immediately before the elevation. It used to
///     be answered once and cached for the lifetime of the backend, so an
///     installation that became writable after the app started was elevated on
///     the strength of a check from minutes earlier (audit C-01).
///   * a protected installation still gets elevated. Refusing everything would
///     satisfy the first point and quietly ship a VPN that never starts, which
///     is why both directions are here.
class _ScriptedProbe implements PathSecurityProbe {
  _ScriptedProbe(this.safeAnswers);

  /// How many inspections answer "protected" before the answers turn hostile.
  final int safeAnswers;
  int inspections = 0;

  @override
  Future<String?> canonicalize(String path) async => path;

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async {
    final safe = inspections++ < safeAnswers;
    return [
      for (final step in steps)
        PathSecurityFacts(
          path: step.path,
          ownerIsPrivileged: safe,
          unprivilegedRights: safe
              ? const {}
              : const {FilesystemRight.createOrWriteContent},
        ),
    ];
  }
}

void main() {
  late Directory workspace;
  late File pkexec;
  late File argv;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('xveil-elevation-');
    argv = File('${workspace.path}/argv.txt');
    pkexec = File('${workspace.path}/pkexec');
    // Stands in for the real thing: records what it was asked to elevate,
    // reports the helper as running, and exits when the backend asks it to
    // stop.
    pkexec.writeAsStringSync('''
#!/bin/sh
{ echo "\$0"; for a in "\$@"; do echo "\$a"; done; } > ${argv.path}
echo '{"phase":"running"}'
read stop_line
exit 0
''');
    expect(posixChmod(pkexec.path, 0x1ED), 0, reason: 'chmod 0755 the stand-in');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  LinuxManagedVpnBackend backendWith(_ScriptedProbe probe) =>
      LinuxManagedVpnBackend(
        isLinuxHost: true,
        executablePath: '/usr/lib/xveil/xveil',
        launchGuard: PrivilegedLaunchGuard(probe: probe, windows: false),
        // Exists, which is all `probe()` asks of the tun device.
        tunDevice: (File('${workspace.path}/tun')..writeAsStringSync('')).path,
        requiredTools: const <String>[],
        resolvePkexec: () => pkexec.path,
      );

  test('a protected installation IS elevated, through the resolved path',
      () async {
    final probe = _ScriptedProbe(1 << 20);
    final backend = backendWith(probe);
    final state = await backend.start(
      // `routeDns` would ask for resolvectl, which this host has not got.
      policy: const VpnRoutingPolicy(routeDns: false),
      socks5Listen: '127.0.0.1:1080',
      exitNodeId: '00' * 32,
    );
    expect(state.phase, VpnBackendPhase.running, reason: state.detail);
    expect(argv.existsSync(), isTrue, reason: 'the stand-in pkexec never ran');
    final recorded = argv.readAsLinesSync();
    expect(recorded.first, pkexec.path, reason: 'ran something else as pkexec');
    expect(recorded[1], '/usr/lib/xveil/xveil');
    expect(recorded[2], '--xveil-vpn-helper');
    expect(recorded[3], endsWith('request.json'));
    await backend.stop();
  });

  test('an installation that goes bad between probe() and elevation is not '
      'elevated', () async {
    // Safe for the checks `start()` makes on the way in, hostile by the time
    // it is about to hand the binary to pkexec. A cached verdict cannot see
    // this; that is the whole defect.
    final probe = _ScriptedProbe(1);
    final backend = backendWith(probe);
    final state = await backend.start(
      // `routeDns` would ask for resolvectl, which this host has not got.
      policy: const VpnRoutingPolicy(routeDns: false),
      socks5Listen: '127.0.0.1:1080',
      exitNodeId: '00' * 32,
    );
    expect(state.phase, VpnBackendPhase.unsupported);
    expect(state.detail, contains('Install xVeil to a protected location'));
    expect(
      argv.existsSync(),
      isFalse,
      reason: 'pkexec was invoked on an installation that had gone writable',
    );
    expect(
      probe.inspections,
      greaterThan(1),
      reason: 'the verdict was cached instead of being asked again',
    );
  });

  test('probe() re-reads the installation every time it is asked', () async {
    final probe = _ScriptedProbe(1);
    final backend = backendWith(probe);
    final first = await backend.probe();
    expect(first.detail, isNot(contains('protected location')));
    final second = await backend.probe();
    expect(second.phase, VpnBackendPhase.unsupported);
    expect(second.detail, contains('Install xVeil to a protected location'));
  });
}
