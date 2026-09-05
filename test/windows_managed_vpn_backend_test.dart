import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/data/vpn/windows_managed_vpn_backend.dart';

void main() {
  test('Windows helper request exposes only the closed privileged schema', () {
    final request = buildWindowsVpnHelperRequest(
      hostPid: 77,
      token: 'ab' * 32,
      socks5Listen: '127.0.0.1:1080',
      expandedPolicy: <String, dynamic>{
        'enabled': true,
        'routeMode': 'excludeOnly',
        'includedCidrs': <String>[],
        'excludedCidrs': <String>['10.0.0.0/8'],
        'routeDns': false,
        'dnsServers': <String>['1.1.1.1'],
        'allowLan': true,
        'mtu': 1400,
        'includedCountryCodes': <String>['KZ'],
        'excludedCountryCodes': <String>['RU'],
      },
    );

    expect(request.keys, ['hostPid', 'token', 'socks5Listen', 'policy']);
    final policy = request['policy']! as Map<String, Object?>;
    expect(policy.keys, [
      'routeMode',
      'includedCidrs',
      'excludedCidrs',
      'routeDns',
      'dnsServers',
      'allowLan',
      'mtu',
    ]);
    expect(policy, isNot(contains('enabled')));
    expect(policy, isNot(contains('includedCountryCodes')));
    expect(policy, isNot(contains('excludedCountryCodes')));
  });

  test('PowerShell elevation quotes paths without interpolation', () {
    final script = buildWindowsVpnElevationScript(
      r"C:\Program Files\x'veil\xveil.exe",
      r'C:\Users\A Name\Temp\request.json',
      'a' * 64,
    );

    expect(script, contains(r"$exe = 'C:\Program Files\x''veil\xveil.exe'"));
    expect(script, contains(r"$request = 'C:\Users\A Name\Temp\request.json'"));
    expect(
      script,
      contains(
        r'''$arguments = '--xveil-vpn-helper "' + $request + '" ' + $digest;''',
      ),
    );
  });

  group('the elevated run is bound to the request (report5 R5-X-03)', () {
    // The request JSON is staged in the user's own %TEMP% because the host is
    // unelevated when it writes it. Every process of that user can rewrite the
    // file while the UAC prompt is on screen, and the helper's read of it is
    // what turns the contents into administrator-level routes, DNS servers and
    // a SOCKS endpoint. The command line of the approved process is the one
    // thing that cannot be changed after the prompt, so the digest goes there.

    test('the digest is carried on the command line, not in the file', () {
      final digest = windowsVpnRequestDigest(
        utf8.encode('{"hostPid":1,"token":"t"}'),
      );
      final script = buildWindowsVpnElevationScript(
        r'C:\xveil\xveil.exe',
        r'C:\Temp\request.json',
        digest,
      );
      expect(script, contains('\$digest = \'$digest\''));
      // And it is APPENDED to the operands the helper receives, outside the
      // quoted path, so the shim sees it as its own argv[3].
      expect(
        script,
        contains(
          r'''$arguments = '--xveil-vpn-helper "' + $request + '" ' + $digest;''',
        ),
      );
    });

    test('a digest that is not one is refused before any launch', () {
      // A caller with nothing to pass must not be able to produce a launch at
      // all: the helper's own check would then be the only thing between a
      // rewritten request and an elevated tunnel, and a shim from another
      // build is exactly the case this defends.
      for (final bad in <String>[
        '',
        'not-a-digest',
        'a' * 63,
        'a' * 65,
        'A' * 64, // the helper is told lowercase hex; produce it, do not guess
        'g' * 64,
      ]) {
        expect(
          () => buildWindowsVpnElevationScript('x.exe', 'r.json', bad),
          throwsArgumentError,
          reason: 'a launch was built from ${bad.isEmpty ? "an empty" : bad} digest',
        );
      }
    });

    test('the runner passes it on, and takes the entry point that wants it', () {
      // The three pieces ship in one bundle — xveil.exe, its runner shim and
      // veil_vpn_helper.dll — so the only failure mode is a half-applied
      // change, and it would be silent: a shim that still passes two operands
      // to an entry point that reads the request on trust.
      final shim = File('windows/runner/vpn_helper.cpp').readAsStringSync();
      expect(
        shim,
        contains('argument_count != 4'),
        reason:
            'the shim accepts a launch without the digest operand, so the '
            'helper is told to expect nothing',
      );
      expect(
        shim,
        contains('veil_run_windows_vpn_helper_v2'),
        reason:
            'the shim resolves the entry point that reads the request on '
            'trust; _v2 is the one that verifies it',
      );
      expect(
        shim,
        contains('helper(request_path.c_str(), request_digest.c_str())'),
        reason: 'the digest is parsed out of argv and then not handed over',
      );
    });

    test('the status is read from where this process cannot write it', () {
      final path = windowsVpnStatusPath(
        r'C:\Users\A Name\AppData\Local\Temp\xveil-vpn-abc123',
        r'C:\ProgramData',
      );
      // The leaf is the session's own name, so two runs never collide and the
      // name is unguessable before the launch.
      expect(path, contains('xveil-vpn-abc123'));
      expect(path, startsWith(r'C:\ProgramData'));
      expect(path, endsWith('status.json'));
      // And NOT beside the request, which is the whole point.
      expect(path, isNot(contains('Temp')));
    });

    test('the helper and the host derive the same place', () {
      // The path is one fact in two languages. If the native side moves it,
      // the host polls a file nobody writes and reports a tunnel that is up as
      // never having started.
      final rust = File(
        'third_party/veil/crates/veil-vpn-helper/src/windows.rs',
      ).readAsStringSync();
      expect(
        rust,
        contains('join("xVeil")'),
        reason: 'the helper no longer publishes under %ProgramData%\\xVeil',
      );
      expect(rust, contains('join("vpn")'));
      expect(rust, contains('join("status.json")'));
      expect(
        rust,
        contains('STATUS_DIR_SDDL'),
        reason:
            'the directory is created without an explicit DACL, so it inherits '
            'whatever the parent grants — which is what made the old status '
            'forgeable',
      );
      // Users read, and nothing else: the host has to poll it.
      expect(rust, contains('(A;OICI;FR;;;BU)'));
      expect(
        rust,
        isNot(contains('(A;OICI;FA;;;BU)')),
        reason: 'Users were granted full control over the status directory',
      );
    });

    test('the stop travels on a pipe named for the session', () {
      final pipe = windowsVpnControlPipe(
        r'C:\Users\A Name\AppData\Local\Temp\xveil-vpn-abc123',
      );
      expect(pipe, r'\\.\pipe\xveil-vpn-abc123');
      // Two runs must not share one: whoever can write to the pipe can ask
      // for a stop, and the name is the only thing separating the runs.
      expect(
        windowsVpnControlPipe(r'C:\Temp\xveil-vpn-zzz'),
        isNot(pipe),
      );
    });

    test('the helper takes the stop from the host, not from a file', () {
      // Not a style check. A file in the session directory is a stop button
      // for every process of this user, and taking down an
      // administrator-level tunnel sends the traffic outside it. A pipe is
      // writable by that user too — same user, same access — so what makes it
      // different is the client-PID check, and losing that would leave the
      // pipe as a file with extra steps.
      final rust = File(
        'third_party/veil/crates/veil-vpn-helper/src/windows.rs',
      ).readAsStringSync();
      expect(
        rust,
        contains('GetNamedPipeClientProcessId'),
        reason: 'the helper no longer asks who is on the other end',
      );
      expect(
        rust,
        contains('client != host_pid'),
        reason: 'any process of this user can stop the tunnel again',
      );
      // The label is what lets the unelevated host write at all: a pipe made
      // by a HIGH-integrity process is not writable by a MEDIUM one without
      // it. Measured on the stand, not assumed.
      expect(
        rust,
        contains('S:(ML;;NW;;;ME)'),
        reason: 'the host cannot write to its own control pipe',
      );
      expect(
        rust,
        isNot(contains('stop_path.exists()')),
        reason: 'the file-based stop is back',
      );
    });

    test('the digest is over the bytes, and moves with them', () {
      final a = utf8.encode('{"routeMode":"all"}');
      final b = utf8.encode('{"routeMode":"nil"}');
      expect(a.length, b.length);
      expect(windowsVpnRequestDigest(a), isNot(windowsVpnRequestDigest(b)));
      // Against an implementation that is not this one.
      expect(
        windowsVpnRequestDigest(const <int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  test(
    'Windows rejects application filtering instead of routing every app',
    () async {
      final result = await WindowsManagedVpnBackend().start(
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
}
