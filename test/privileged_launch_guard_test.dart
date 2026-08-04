import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/linux_managed_vpn_backend.dart';
import 'package:xveil/data/vpn/privileged_launch_guard.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/vpn_routing_policy.dart';
import 'package:xveil/data/vpn/windows_managed_vpn_backend.dart';

/// A stand-in platform: the test says what each path looks like, and the guard
/// has to reach the same conclusion it would from a real DACL or `stat`.
class _FakeProbe implements PathSecurityProbe {
  _FakeProbe(this.facts, {this.canonical, this.throwOnInspect = false});

  /// path -> facts. Anything absent comes back undetermined, which is the
  /// fail-closed default the real probes also promise.
  final Map<String, PathSecurityFacts> facts;
  final String? canonical;
  final bool throwOnInspect;

  List<PrivilegedPathStep> seen = const [];

  @override
  Future<String?> canonicalize(String path) async => canonical ?? path;

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async {
    seen = steps;
    if (throwOnInspect) throw StateError('no ACL for you');
    return [
      for (final step in steps)
        facts[step.path] ??
            PathSecurityFacts.undetermined(step.path, 'not described'),
    ];
  }
}

PathSecurityFacts _safe(String path) => PathSecurityFacts(
  path: path,
  ownerIsPrivileged: true,
  unprivilegedRights: const {},
);

PathSecurityFacts _writable(String path) => PathSecurityFacts(
  path: path,
  ownerIsPrivileged: true,
  unprivilegedRights: const {
    FilesystemRight.createOrWriteContent,
    FilesystemRight.deleteChild,
  },
);

/// A protected Windows install: `C:\Program Files\xVeil\xveil.exe`, with the
/// real-world quirk that `C:\` lets any user create folders in it.
Map<String, PathSecurityFacts> _protectedWindowsInstall() => {
  r'C:\Program Files\xVeil\xveil.exe': _safe(
    r'C:\Program Files\xVeil\xveil.exe',
  ),
  r'C:\Program Files\xVeil': _safe(r'C:\Program Files\xVeil'),
  r'C:\Program Files': _safe(r'C:\Program Files'),
  r'C:\': const PathSecurityFacts(
    path: r'C:\',
    ownerIsPrivileged: true,
    // BUILTIN\Users:(CI)(AD) — the stock ACL of every Windows drive root.
    unprivilegedRights: {FilesystemRight.createOrWriteContent},
  ),
};

Map<String, PathSecurityFacts> _protectedLinuxInstall() => {
  '/usr/lib/xveil/xveil': _safe('/usr/lib/xveil/xveil'),
  '/usr/lib/xveil': _safe('/usr/lib/xveil'),
  '/usr/lib': _safe('/usr/lib'),
  '/usr': _safe('/usr'),
  '/': _safe('/'),
};

void main() {
  group('the chain that has to be safe', () {
    test('Windows walks the executable up to the drive root', () {
      final chain = privilegedPathChain(
        r'C:\Program Files\xVeil\xveil.exe',
        windows: true,
      );
      expect(chain.map((step) => step.path), [
        r'C:\Program Files\xVeil\xveil.exe',
        r'C:\Program Files\xVeil',
        r'C:\Program Files',
        r'C:\',
      ]);
      expect(chain.map((step) => step.role), [
        PrivilegedPathRole.executable,
        PrivilegedPathRole.executableDirectory,
        PrivilegedPathRole.ancestorDirectory,
        PrivilegedPathRole.ancestorDirectory,
      ]);
    });

    test('Linux walks the executable up to /', () {
      final chain = privilegedPathChain('/opt/xveil/bin/xveil', windows: false);
      expect(chain.map((step) => step.path), [
        '/opt/xveil/bin/xveil',
        '/opt/xveil/bin',
        '/opt/xveil',
        '/opt',
        '/',
      ]);
      expect(chain.last.role, PrivilegedPathRole.ancestorDirectory);
    });
  });

  group('the decision for one path', () {
    test('an unreadable entry refuses — never "probably fine"', () {
      expect(
        refusalFor(
          const PathSecurityFacts.undetermined('/opt/x', 'stat exploded'),
          PrivilegedPathRole.executable,
        ),
        contains('could not be read'),
      );
    });

    test('an unprivileged owner refuses even with a spotless ACL', () {
      expect(
        refusalFor(
          const PathSecurityFacts(
            path: '/home/v/xVeil/xveil',
            ownerIsPrivileged: false,
            unprivilegedRights: {},
          ),
          PrivilegedPathRole.executable,
        ),
        contains('not an administrator'),
      );
    });

    test('creating entries is fatal beside the binary, fine further up', () {
      const creatable = PathSecurityFacts(
        path: r'C:\',
        ownerIsPrivileged: true,
        unprivilegedRights: {FilesystemRight.createOrWriteContent},
      );
      // Beside the binary this is DLL planting: the loader takes the process's
      // libraries from here before any code of ours runs.
      expect(
        refusalFor(creatable, PrivilegedPathRole.executableDirectory),
        isNotNull,
      );
      // Higher up it is the stock ACL of `C:\` and reaches nothing of ours.
      expect(
        refusalFor(creatable, PrivilegedPathRole.ancestorDirectory),
        isNull,
      );
    });

    test('deleting the child is fatal at every level', () {
      const deletable = PathSecurityFacts(
        path: r'C:\Program Files',
        ownerIsPrivileged: true,
        unprivilegedRights: {FilesystemRight.deleteChild},
      );
      expect(
        refusalFor(deletable, PrivilegedPathRole.ancestorDirectory),
        contains('delete or rename what it contains'),
      );
    });

    for (final right in FilesystemRight.values) {
      test('${right.name} beside the binary refuses', () {
        expect(
          refusalFor(
            PathSecurityFacts(
              path: 'x',
              ownerIsPrivileged: true,
              unprivilegedRights: {right},
            ),
            PrivilegedPathRole.executableDirectory,
          ),
          isNotNull,
        );
      });
    }
  });

  group('Windows: a protected install is allowed', () {
    test('Program Files passes, drive-root AddSubdirectory and all', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(_protectedWindowsInstall()),
        windows: true,
      ).inspect(r'C:\Program Files\xVeil\xveil.exe');
      expect(verdict.isAllowed, isTrue, reason: verdict.detail);
    });
  });

  group('Windows: a portable unpack is refused', () {
    test('a user-owned folder beside the binary', () async {
      const exe = r'C:\Users\v\Downloads\xVeil\xveil.exe';
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe({
          exe: _safe(exe),
          r'C:\Users\v\Downloads\xVeil': const PathSecurityFacts(
            path: r'C:\Users\v\Downloads\xVeil',
            ownerIsPrivileged: false,
            unprivilegedRights: {FilesystemRight.createOrWriteContent},
          ),
          r'C:\Users\v\Downloads': _safe(r'C:\Users\v\Downloads'),
          r'C:\Users\v': _safe(r'C:\Users\v'),
          r'C:\Users': _safe(r'C:\Users'),
          r'C:\': _safe(r'C:\'),
        }),
        windows: true,
      ).inspect(exe);
      expect(verdict.isAllowed, isFalse);
      expect(verdict.offendingPath, r'C:\Users\v\Downloads\xVeil');
      expect(verdict.detail, contains('Install xVeil to a protected location'));
    });

    test('a network share is refused without asking anybody', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(const {}),
        windows: true,
      ).inspect(r'\\fileserver\share\xVeil\xveil.exe');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.reason, contains('network share'));
    });
  });

  group('Linux: both sides', () {
    test('/usr/lib install is allowed', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(_protectedLinuxInstall()),
        windows: false,
      ).inspect('/usr/lib/xveil/xveil');
      expect(verdict.isAllowed, isTrue, reason: verdict.detail);
    });

    test(r'an unpacked tarball in $HOME is refused', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe({
          '/home/v/xVeil/xveil': const PathSecurityFacts(
            path: '/home/v/xVeil/xveil',
            ownerIsPrivileged: false,
            unprivilegedRights: {FilesystemRight.createOrWriteContent},
          ),
          '/home/v/xVeil': _writable('/home/v/xVeil'),
          '/home/v': _writable('/home/v'),
          '/home': _safe('/home'),
          '/': _safe('/'),
        }),
        windows: false,
      ).inspect('/home/v/xVeil/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.offendingPath, '/home/v/xVeil/xveil');
    });

    test(
      'a root-owned binary under a writable PARENT is still refused',
      () async {
        // The whole point of walking to the root: /opt/xveil and the binary in it
        // are immaculate, but anybody can rename /opt/xveil away and put their
        // own directory of the same name there.
        final verdict = await PrivilegedLaunchGuard(
          probe: _FakeProbe({
            '/opt/xveil/xveil': _safe('/opt/xveil/xveil'),
            '/opt/xveil': _safe('/opt/xveil'),
            '/opt': _writable('/opt'),
            '/': _safe('/'),
          }),
          windows: false,
        ).inspect('/opt/xveil/xveil');
        expect(verdict.isAllowed, isFalse);
        expect(verdict.offendingPath, '/opt');
        expect(verdict.reason, contains('delete or rename what it contains'));
      },
    );

    test('a writable GRANDparent is refused too', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe({
          '/srv/a/b/xveil': _safe('/srv/a/b/xveil'),
          '/srv/a/b': _safe('/srv/a/b'),
          '/srv/a': _safe('/srv/a'),
          '/srv': _writable('/srv'),
          '/': _safe('/'),
        }),
        windows: false,
      ).inspect('/srv/a/b/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.offendingPath, '/srv');
    });

    test('a symlink into a safe place still checks where it SITS', () async {
      // /opt/app -> /usr/lib/xveil. Everything the link points at is root-owned,
      // but /opt is writable, so the link can simply be repointed at /tmp/evil.
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe({
          ..._protectedLinuxInstall(),
          '/opt/app/xveil': _safe('/opt/app/xveil'),
          '/opt/app': _safe('/opt/app'),
          '/opt': _writable('/opt'),
        }, canonical: '/usr/lib/xveil/xveil'),
        windows: false,
      ).inspect('/opt/app/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.offendingPath, '/opt');
    });

    test('a path that cannot be resolved refuses', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _NoCanonicalProbe(),
        windows: false,
      ).inspect('/opt/xveil/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.reason, contains('could not be resolved'));
    });

    test('a probe that throws refuses instead of letting it through', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(_protectedLinuxInstall(), throwOnInspect: true),
        windows: false,
      ).inspect('/usr/lib/xveil/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.reason, contains('could not be read'));
    });

    test('a path the probe simply skipped refuses', () async {
      final partial = _protectedLinuxInstall()..remove('/usr');
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(partial),
        windows: false,
      ).inspect('/usr/lib/xveil/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.offendingPath, '/usr');
    });

    test('a relative path refuses', () async {
      final verdict = await PrivilegedLaunchGuard(
        probe: _FakeProbe(const {}),
        windows: false,
      ).inspect('build/linux/xveil');
      expect(verdict.isAllowed, isFalse);
      expect(verdict.reason, contains('absolute'));
    });
  });

  group('the Windows fact layer, without a Windows host', () {
    test('the rights bitmask maps to the rights that matter', () {
      expect(windowsRightsFromMask(0x2), {
        FilesystemRight.createOrWriteContent,
      });
      expect(windowsRightsFromMask(0x40), {FilesystemRight.deleteChild});
      expect(windowsRightsFromMask(0x10000), {FilesystemRight.delete});
      expect(windowsRightsFromMask(0x40000), {
        FilesystemRight.changePermissions,
      });
      expect(windowsRightsFromMask(0x80000), {FilesystemRight.takeOwnership});
      // Read & Execute — the grant every user has on Program Files.
      expect(windowsRightsFromMask(0x1200A9), isEmpty);
      // FullControl, and GENERIC_ALL for ACEs that were never canonicalized.
      expect(
        windowsRightsFromMask(0x1F01FF),
        containsAll(FilesystemRight.values),
      );
      expect(
        windowsRightsFromMask(0x10000000),
        containsAll(FilesystemRight.values),
      );
    });

    test('an inherit-only CREATOR OWNER ACE grants nothing here', () {
      final facts = windowsFactsFromAcl(r'C:\Program Files', {
        'owner': 'S-1-5-32-544',
        'rules': [
          {
            'sid': 'S-1-3-0',
            'rights': 0x1F01FF,
            'allow': true,
            'inheritOnly': true,
          },
          {
            'sid': 'S-1-5-32-545',
            'rights': 0x1200A9,
            'allow': true,
            'inheritOnly': false,
          },
        ],
      });
      expect(facts.undeterminedReason, isNull);
      expect(facts.ownerIsPrivileged, isTrue);
      expect(facts.unprivilegedRights, isEmpty);
    });

    test('a user with Modify beside the binary is caught', () {
      final facts = windowsFactsFromAcl(r'C:\Users\v\xVeil', {
        'owner': 'S-1-5-21-1-2-3-1001',
        'rules': [
          {
            'sid': 'S-1-5-21-1-2-3-1001',
            'rights': 0x301BF, // Modify
            'allow': true,
            'inheritOnly': false,
          },
        ],
      });
      expect(facts.ownerIsPrivileged, isFalse);
      expect(
        facts.unprivilegedRights,
        contains(FilesystemRight.createOrWriteContent),
      );
    });

    test('a deny entry never rescues an allow entry', () {
      final facts = windowsFactsFromAcl('x', {
        'owner': 'S-1-5-18',
        'rules': [
          {
            'sid': 'S-1-5-32-545',
            'rights': 0x1F01FF,
            'allow': true,
            'inheritOnly': false,
          },
          {
            'sid': 'S-1-5-32-545',
            'rights': 0x1F01FF,
            'allow': false,
            'inheritOnly': false,
          },
        ],
      });
      expect(facts.unprivilegedRights, isNotEmpty);
    });

    test('a Get-Acl error on one path leaves that path undetermined', () {
      final facts = windowsFactsFromAcl('x', {
        'path': 'x',
        'error': 'Attempted to perform an unauthorized operation.',
      });
      expect(facts.undeterminedReason, contains('unauthorized'));
    });

    test('unparsable PowerShell output leaves every path undetermined', () {
      final facts = decodeWindowsAclReport([
        r'C:\',
        r'C:\x',
      ], 'not json at all');
      expect(facts, hasLength(2));
      expect(facts.every((f) => f.undeterminedReason != null), isTrue);
    });

    test('a single-path answer that PowerShell un-arrayed still decodes', () {
      final facts = decodeWindowsAclReport(
        [r'C:\'],
        jsonEncode({'path': r'C:\', 'owner': 'S-1-5-18', 'rules': <Object>[]}),
      );
      expect(facts.single.undeterminedReason, isNull);
      expect(facts.single.ownerIsPrivileged, isTrue);
    });

    test('the ACL script quotes paths without interpolating them', () {
      final script = buildWindowsAclScript([r"C:\x'veil", r'C:\Program Files']);
      expect(script, contains(r"@('C:\x''veil','C:\Program Files')"));
      expect(script, contains('Get-Acl -LiteralPath'));
      expect(script, isNot(contains(r'$($')));
    });
  });

  group('the backends refuse at the point of decision', () {
    test('Windows probe() refuses a writable installation', () async {
      const exe = r'C:\Users\v\Downloads\xVeil\xveil.exe';
      final state = await WindowsManagedVpnBackend(
        isWindowsHost: true,
        executablePath: exe,
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe({
            exe: _safe(exe),
            r'C:\Users\v\Downloads\xVeil': _writable(
              r'C:\Users\v\Downloads\xVeil',
            ),
            r'C:\Users\v\Downloads': _safe(r'C:\Users\v\Downloads'),
            r'C:\Users\v': _safe(r'C:\Users\v'),
            r'C:\Users': _safe(r'C:\Users'),
            r'C:\': _safe(r'C:\'),
          }),
          windows: true,
        ),
      ).probe();
      expect(state.phase, VpnBackendPhase.unsupported);
      expect(state.detail, contains('Install xVeil to a protected location'));
    });

    test('Windows start() will not elevate a writable installation', () async {
      const exe = r'C:\Users\v\Downloads\xVeil\xveil.exe';
      final state =
          await WindowsManagedVpnBackend(
            isWindowsHost: true,
            executablePath: exe,
            launchGuard: PrivilegedLaunchGuard(
              probe: _FakeProbe({exe: _writable(exe)}),
              windows: true,
            ),
          ).start(
            policy: const VpnRoutingPolicy(),
            socks5Listen: '127.0.0.1:1080',
            exitNodeId: '00' * 32,
          );
      expect(state.phase, VpnBackendPhase.unsupported);
      expect(state.detail, contains('elevates this executable'));
    });

    test('Windows probe() gets PAST the guard when protected', () async {
      final state = await WindowsManagedVpnBackend(
        isWindowsHost: true,
        executablePath: r'C:\Program Files\xVeil\xveil.exe',
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe(_protectedWindowsInstall()),
          windows: true,
        ),
      ).probe();
      // Still unsupported on this host — there is no `veil_vpn_helper.dll` on a
      // Mac — but for the NEXT reason down, which is what proves the guard let
      // it through instead of swallowing the feature wholesale.
      expect(state.detail, isNot(contains('protected location')));
      expect(state.detail, contains('missing Windows VPN components'));
    });

    test('Linux probe() refuses an unpacked tarball', () async {
      final state = await LinuxManagedVpnBackend(
        isLinuxHost: true,
        executablePath: '/home/v/xVeil/xveil',
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe({
            '/home/v/xVeil/xveil': _safe('/home/v/xVeil/xveil'),
            '/home/v/xVeil': _writable('/home/v/xVeil'),
            '/home/v': _writable('/home/v'),
            '/home': _safe('/home'),
            '/': _safe('/'),
          }),
          windows: false,
        ),
      ).probe();
      expect(state.phase, VpnBackendPhase.unsupported);
      expect(state.detail, contains('Install xVeil to a protected location'));
    });

    test('Linux probe() gets PAST the guard when protected', () async {
      final state = await LinuxManagedVpnBackend(
        isLinuxHost: true,
        executablePath: '/usr/lib/xveil/xveil',
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe(_protectedLinuxInstall()),
          windows: false,
        ),
      ).probe();
      expect(state.detail, isNot(contains('protected location')));
      // The next check down is /dev/net/tun, which no Mac has.
      expect(state.detail, contains('/dev/net/tun'));
    });

    test('Linux start() will not pkexec a writable installation', () async {
      final state =
          await LinuxManagedVpnBackend(
            isLinuxHost: true,
            executablePath: '/home/v/xVeil/xveil',
            launchGuard: PrivilegedLaunchGuard(
              probe: _FakeProbe({
                '/home/v/xVeil/xveil': _writable('/home/v/xVeil/xveil'),
              }),
              windows: false,
            ),
          ).start(
            policy: const VpnRoutingPolicy(),
            socks5Listen: '127.0.0.1:1080',
            exitNodeId: '00' * 32,
          );
      expect(state.phase, VpnBackendPhase.unsupported);
      expect(state.detail, contains('elevates this executable'));
    });
  });
}

class _NoCanonicalProbe implements PathSecurityProbe {
  @override
  Future<String?> canonicalize(String path) async => null;

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async => const [];
}
