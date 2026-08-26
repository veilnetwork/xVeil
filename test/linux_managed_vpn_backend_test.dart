import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'support/expect_before.dart';
import 'package:xveil/data/vpn/linux_managed_vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';

void main() {
  test('Linux helper request exposes only the closed privileged schema', () {
    final request = buildLinuxVpnHelperRequest(
      hostPid: 42,
      socks5Listen: '127.0.0.1:1080',
      expandedPolicy: <String, dynamic>{
        'enabled': true,
        'routeMode': 'excludeOnly',
        'includedCidrs': <String>[],
        'excludedCidrs': <String>['203.0.113.0/24'],
        'includedCountryCodes': <String>[],
        'excludedCountryCodes': <String>['KZ'],
        'geoIpGeneratedAt': '2026-07-20',
        'routeDns': false,
        'dnsServers': <String>['1.1.1.1'],
        'allowLan': true,
        'mtu': 1280,
      },
    );

    expect(request['hostPid'], 42);
    expect(request['socks5Listen'], '127.0.0.1:1080');
    final policy = request['policy']! as Map<String, Object?>;
    expect(policy.keys, <String>{
      'routeMode',
      'includedCidrs',
      'excludedCidrs',
      'routeDns',
      'dnsServers',
      'allowLan',
      'mtu',
    });
    expect(policy['excludedCidrs'], <String>['203.0.113.0/24']);
    expect(policy['routeDns'], isFalse);
    expect(policy, isNot(contains('enabled')));
    expect(policy, isNot(contains('geoIpGeneratedAt')));
  });

  test(
    'Linux rejects application filtering instead of routing every app',
    () async {
      final result = await LinuxManagedVpnBackend().start(
        policy: const VpnRoutingPolicy(
          applicationMode: VpnApplicationMode.onlySelected,
          applicationIds: ['org.mozilla.firefox'],
        ),
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: '00' * 32,
        exitNodeIds: ['00' * 32],
      );
      expect(result.phase, VpnBackendPhase.error);
      expect(result.detail, contains('not supported'));
    },
  );

  group('a helper that was not seen to exit', () {
    // `stop` released the handle unconditionally: it signalled the helper,
    // waited, and cleared `_helper` and `_exitCode` whether or not the process
    // was ever seen to go. A second `stop` then had nothing to signal and
    // answered "stopped" at once — while the helper, for all anybody knew, was
    // still holding the tun device and the routes it installed
    // (report16 XV-07).
    //
    // Structural, and this is why: the helper is a privileged process started
    // with `Process.start`, with no seam to put a fake behind. What can be
    // checked is that neither path lets go of the handle without having seen
    // the exit.
    final source = File(
      'lib/data/vpn/linux_managed_vpn_backend.dart',
    ).readAsStringSync();

    test('keeps its handle, on both paths', () {
      for (final release in RegExp(
        r'await _releaseHelper\(\);',
      ).allMatches(source)) {
        final before = source.substring(
          (release.start - 400).clamp(0, source.length),
          release.start,
        );
        expect(
          before,
          anyOf(
            // Seen to exit within the window...
            contains('if (exited)'),
            // ...or the clean stop, which awaits the exit itself and only
            // reaches the release if that await returned. Matched by its OWN
            // text: `.timeout(_stopTimeout)` alone appears in the error path
            // too, and accepting it there let `if (exited)` be replaced by
            // `if (true)` with this still green.
            contains('helper.exitCode).timeout(_stopTimeout);'),
            // ...or already known to have finished before this was called.
            contains('completed != null'),
          ),
          reason:
              'a release here happens whether or not the process was seen to '
              'go, and the PID is the only way back to it',
        );
      }
    });

    test('and the timeout is not signalled by a fake exit code', () {
      // `onTimeout: () => -1` cannot be told from a real answer: a process
      // killed by a signal exits NEGATIVE on POSIX, so -1 is a value the
      // platform can genuinely return. The distinction is now a caught
      // TimeoutException rather than a sentinel.
      expect(source, isNot(contains('onTimeout: () => -1')));
    });

    test('and says so rather than saying stopped', () {
      expect(source, contains('may still be up'));
      expectBefore(source, 'may still be up', 'Future<List<String>> _missingTools');
    });
  });
}
