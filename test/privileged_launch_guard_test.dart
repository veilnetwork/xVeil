import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
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
  _posixFactLayerTests();

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
      // Named component, not the real one, for the reason its Linux sibling
      // above records: relying on the HOST to be missing a file makes the case
      // pass on a developer's Mac and fail on Windows, where the DLL beside the
      // executable is exactly what a real installation has.
      const absentComponent = 'xveil-test-absent-component.dll';
      final state = await WindowsManagedVpnBackend(
        isWindowsHost: true,
        executablePath: r'C:\Program Files\xVeil\xveil.exe',
        requiredComponents: const [absentComponent],
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe(_protectedWindowsInstall()),
          windows: true,
        ),
      ).probe();
      // Still unsupported, but for the NEXT reason down, which is what proves
      // the guard let it through instead of swallowing the feature wholesale.
      expect(state.detail, isNot(contains('protected location')));
      expect(state.detail, contains('missing Windows VPN components'));
      expect(state.detail, contains(absentComponent));
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
      // The tun path is injected rather than left at its default, and that is
      // the whole point of the case. It used to rely on the HOST not having
      // `/dev/net/tun` — true on the Mac this is usually run on, false on the
      // Linux this test is named after. So it passed where it did not matter
      // and failed where it did: on a real Linux box the probe gets past the
      // device too, `detail` is null, and the assertion below blew up on a
      // machine that was behaving correctly.
      const absentTun = '/nonexistent/xveil-test/net/tun';
      final state = await LinuxManagedVpnBackend(
        isLinuxHost: true,
        executablePath: '/usr/lib/xveil/xveil',
        tunDevice: absentTun,
        launchGuard: PrivilegedLaunchGuard(
          probe: _FakeProbe(_protectedLinuxInstall()),
          windows: false,
        ),
      ).probe();
      expect(state.detail, isNot(contains('protected location')));
      // Stopped at the NEXT check down, which is what proves the guard let it
      // through instead of swallowing the feature wholesale.
      expect(state.detail, contains(absentTun));
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

PosixFileFacts _stat({
  int uid = 0,
  int mode = 0x81ED, // regular file, 0755
  int inode = 7,
  int deviceId = 1,
}) => PosixFileFacts(
  deviceId: deviceId,
  inode: inode,
  uid: uid,
  gid: 0,
  mode: mode,
);

/// The POSIX fact layer, which no longer runs anything.
void _posixFactLayerTests() {
  group('POSIX facts come from lstat, not from a program', () {
    test('a failed lstat is undetermined, never optimistic', () {
      final facts = posixFactsFromStat('/opt/x', null);
      expect(facts.undeterminedReason, isNotNull);
      expect(
        refusalFor(facts, PrivilegedPathRole.executable),
        contains('could not be read'),
      );
    });

    test('root-owned and unwritable is the only clean answer', () {
      final facts = posixFactsFromStat('/usr/bin', _stat(mode: 0x41ED));
      expect(facts.ownerIsPrivileged, isTrue);
      expect(facts.unprivilegedRights, isEmpty);
      expect(refusalFor(facts, PrivilegedPathRole.executable), isNull);
    });

    test('a group- or other-writable entry grants both write and delete', () {
      for (final mode in const [0x41FF, 0x41FD, 0x41EF]) {
        // 0777, 0775, 0757 — group write, other write.
        final facts = posixFactsFromStat('/opt/x', _stat(mode: mode));
        expect(
          facts.unprivilegedRights,
          containsAll(const [
            FilesystemRight.createOrWriteContent,
            FilesystemRight.deleteChild,
          ]),
          reason: 'mode ${mode.toRadixString(8)}',
        );
      }
    });

    test('a non-root owner refuses whatever the mode says', () {
      final facts = posixFactsFromStat('/opt/x', _stat(uid: 501, mode: 0x41C0));
      expect(facts.ownerIsPrivileged, isFalse);
      expect(
        refusalFor(facts, PrivilegedPathRole.executable),
        contains('not an administrator'),
      );
    });

    test('a symlink is judged by its owner, not by its meaningless 0777', () {
      // lstat on a link reports 0777 on Linux — treating that as "world
      // writable" would refuse every distribution that puts a link in /usr/bin,
      // and treating the link's mode as evidence of anything would be a lie.
      // Where it POINTS is walked as its own chain; where it SITS is the parent
      // step, which is checked in its own right.
      final rootLink = posixFactsFromStat('/usr/bin/x', _stat(mode: 0xA1FF));
      expect(rootLink.ownerIsPrivileged, isTrue);
      expect(rootLink.unprivilegedRights, isEmpty);
      expect(refusalFor(rootLink, PrivilegedPathRole.executable), isNull);

      final userLink = posixFactsFromStat(
        '/usr/bin/x',
        _stat(uid: 501, mode: 0xA1FF),
      );
      expect(refusalFor(userLink, PrivilegedPathRole.executable), isNotNull);
    });

    test('lstat reads the real filesystem, and reads it as lstat', () {
      final dir = Directory.systemTemp.createTempSync('xveil-lstat-');
      try {
        final target = File('${dir.path}/target')..writeAsStringSync('x');
        final link = Link('${dir.path}/link')..createSync(target.path);

        expect(posixChmod(target.path, 0x1FF), 0); // 0777
        final file = posixLstat(target.path);
        expect(file, isNotNull);
        expect(file!.isRegularFile, isTrue);
        expect(file.isSymlink, isFalse);
        expect(file.groupOrOtherWritable, isTrue);
        expect(file.uid, posixEuid());
        expect(file.uid, isNot(0), reason: 'the suite must not run as root');

        final linkFacts = posixLstat(link.path);
        expect(linkFacts, isNotNull);
        expect(
          linkFacts!.isSymlink,
          isTrue,
          reason: 'lstat must not follow the last component',
        );

        expect(posixChmod(target.path, 0x1C0), 0); // 0700
        expect(posixLstat(target.path)!.groupOrOtherWritable, isFalse);

        expect(posixLstat('${dir.path}/does-not-exist'), isNull);

        // The one path every POSIX host agrees about.
        final root = posixLstat('/');
        expect(root, isNotNull);
        expect(root!.uid, 0);
        expect(root.isDirectory, isTrue);
        expect(root.groupOrOtherWritable, isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, skip: Platform.isWindows ? 'POSIX only' : null);
  });

  group('the helper we would elevate through is named absolutely', () {
    test('the first root-owned, unwritable file wins', () {
      expect(
        resolveTrustedPosixTool(
          const ['/usr/bin/pkexec', '/bin/pkexec'],
          stat: (path) => path == '/bin/pkexec' ? _stat() : null,
        ),
        '/bin/pkexec',
      );
    });

    test('a user-owned, a writable, a linked and a missing one are all '
        'skipped', () {
      final rejected = <String, PosixFileFacts?>{
        '/a/pkexec': _stat(uid: 501), // somebody else's
        '/b/pkexec': _stat(mode: 0x81FF), // 0777
        '/c/pkexec': _stat(mode: 0x81F6), // 0766, group+other write
        '/d/pkexec': _stat(mode: 0xA1FF), // a symlink
        '/e/pkexec': null, // not there at all
      };
      for (final entry in rejected.entries) {
        expect(
          resolveTrustedPosixTool(
            [entry.key],
            stat: (path) => path == entry.key ? entry.value : null,
          ),
          isNull,
          reason: entry.key,
        );
      }
      expect(
        resolveTrustedPosixTool(
          rejected.keys.toList(),
          stat: (path) => rejected[path],
        ),
        isNull,
      );
    });

    test('nothing in this suite`s own workspace can ever qualify', () {
      final dir = Directory.systemTemp.createTempSync('xveil-tool-');
      try {
        final planted = File('${dir.path}/pkexec')
          ..writeAsStringSync('#!/bin/sh\nexec /usr/bin/pkexec "\$@"\n');
        expect(posixChmod(planted.path, 0x1ED), 0);
        // The whole point: it exists, it is executable, it even forwards to the
        // real thing — and it is ours, so it is not a path to root.
        expect(resolveTrustedPosixTool([planted.path]), isNull);
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, skip: Platform.isWindows ? 'POSIX only' : null);

    test('the candidate list is absolute, with no bare names left', () {
      expect(kPkexecCandidates, isNotEmpty);
      for (final candidate in kPkexecCandidates) {
        expect(candidate, startsWith('/'));
      }
    });
  });

  group('Windows helpers are absolute and do not pass our environment on', () {
    test('SystemRoot is honoured when it is a rooted local path', () {
      expect(
        windowsSystemRoot(environment: {'SystemRoot': r'D:\Windows'}),
        r'D:\Windows',
      );
      expect(
        windowsSystemRoot(environment: {'SystemRoot': r'D:\Windows\'}),
        r'D:\Windows',
      );
    });

    test('anything else falls back instead of being concatenated in', () {
      for (final hostile in const [
        r'\\attacker\share',
        'relative',
        '',
        r'..\..\tmp',
      ]) {
        expect(
          windowsSystemRoot(environment: {'SystemRoot': hostile}),
          r'C:\Windows',
          reason: hostile,
        );
      }
      expect(windowsSystemRoot(environment: const {}), r'C:\Windows');
    });

    test('PowerShell and System32 tools are named by absolute path', () {
      expect(
        windowsPowerShellPath(environment: {'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(
        windowsSystem32Tool('tasklist.exe', environment: {
          'SystemRoot': r'C:\Windows',
        }),
        r'C:\Windows\System32\tasklist.exe',
      );
    });

    test('the helper environment carries no search path of ours', () {
      final env = windowsCleanEnvironment(
        environment: {
          'SystemRoot': r'C:\Windows',
          'Path': r'C:\Users\v\evil;C:\Windows\System32',
          'PSModulePath': r'C:\Users\v\evil\modules',
        },
      );
      expect(env['Path'], isNot(contains('evil')));
      expect(env, isNot(contains('PSModulePath')));
      expect(env['SystemRoot'], r'C:\Windows');
      for (final entry in env['Path']!.split(';')) {
        expect(entry, startsWith(r'C:\Windows'));
      }
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
