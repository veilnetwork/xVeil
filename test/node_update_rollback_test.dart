import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_auto_update.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/node_provisioner.dart';

import 'support/expect_before.dart';

/// What the update scripts do when the new binary does not come back.
///
/// The existing tests assert that the rollback lines are PRESENT and in the
/// right order. Presence is not execution: both scripts run under
/// `set -euo pipefail`, and a bare `systemctl restart` that returns non-zero
/// ends the shell on the spot — several lines above the restore it was
/// supposed to reach. The rollback read correctly and could never run.
///
/// So these run the real generated script with the commands it calls replaced
/// by stubs, and assert on what it actually did.
void main() {
  /// Run [script] with every external command it uses replaced by a stub that
  /// appends to a log, and return the log lines.
  ///
  /// `systemctl restart` fails when [restartFails], and `is-active` reports
  /// dead for [deadChecks] calls before recovering — which is how a service
  /// that starts and immediately exits looks from outside.
  List<String> runStubbed(
    String script, {
    bool restartFails = false,
    int deadChecks = 0,
    int aliveChecks = 0,
    bool backupFails = false,
    bool binaryInstalled = true,
  }) {
    final dir = Directory.systemTemp.createTempSync('xveil-rb');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = '${dir.path}/log';
    // Real paths, not a stubbed `test` that says a file exists while `cp`
    // finds it does not. Two fictions that disagree is how a harness starts
    // deciding outcomes on its own.
    final bin = Directory('${dir.path}/bin')..createSync();
    if (binaryInstalled) {
      File('${bin.path}/veil-cli').writeAsStringSync('#!/bin/sh\nexit 0\n');
    }
    final harness =
        '''
LOG='$log'
: > "\$LOG"
note() { echo "\$*" >> "\$LOG"; }
sudo() { "\$@"; }
uname() { echo x86_64; }
tee() { cat > /dev/null; note "tee \$*"; }
chown() { note "chown \$*"; }
chmod() { note "chmod \$*"; }
daemon-reload() { :; }
curl() {
  local out="" prev=""
  for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
  if [ -n "\$out" ]; then
    case "\$out" in
      *sums)
        echo 'deadbeef  veil-cli' > "\$out" ;;
      *)
        # A real ELF header for this machine: 62 (0x3e) at offset 18.
        printf '\\177ELF\\2\\1\\1\\0\\0\\0\\0\\0\\0\\0\\0\\0\\2\\0\\076\\0' > "\$out" ;;
    esac
    note "curl -o \$out"
  else
    echo '{"tag_name": "v9.9.9"}'
    note "curl json"
  fi
}
sha256sum() {
  if [ "\$1" = "-c" ]; then cat > /dev/null; note "sha256sum -c"; return 0; fi
  note "sha256sum \$*"; echo "deadbeef  \$1"
}
cp() {
  note "cp \$*"
  # Faithful in two ways that decide tests: the real one FAILS when the source
  # is not there (which is the clean-install case), and it leaves a file
  # behind when it works — the script asks `[ -f ]` about that afterwards, and
  # `[` is a builtin, so it sees the filesystem and not these stubs.
  local args=("\$@")
  local src="\${args[\${#args[@]}-2]}"
  local dst="\${args[\${#args[@]}-1]}"
  [ -e "\$src" ] || return 1
  if [ ${backupFails ? 1 : 0} -eq 0 ]; then : > "\$dst"; fi
  return ${backupFails ? 1 : 0}
}
install() {
  note "install \$*"
  local args=("\$@")
  local src="\${args[\${#args[@]}-2]}"
  local dst="\${args[\${#args[@]}-1]}"
  [ -e "\$src" ] || return 1
  : > "\$dst"
}
mv() { note "mv \$*"; return 0; }
DEAD=$deadChecks
ALIVE=$aliveChecks
SEEN=0
systemctl() {
  note "systemctl \$*"
  case "\$1" in
    restart) return ${restartFails ? 1 : 0} ;;
    is-active)
      # The FIRST question is the snapshot taken before the install: was this
      # service running at all. Answering "no" there is a different scenario -
      # the script correctly leaves a stopped service stopped - so the health
      # checks only start failing afterwards.
      if [ "\$SEEN" = 0 ]; then SEEN=1; return 0; fi
      # Alive for a while, then not: a unit is reported active the instant it
      # is started, and a binary that cannot run exits just after.
      if [ "\$ALIVE" -gt 0 ]; then ALIVE=\$((ALIVE - 1)); return 0; fi
      if [ "\$DEAD" -gt 0 ]; then DEAD=\$((DEAD - 1)); return 1; fi
      return 0 ;;
  esac
  return 0
}
sleep() { :; }
mkdir() { :; }
tee() {
  # The real one writes to its FILE arguments; the script uses `tee FILE
  # >/dev/null`, so the destination is the first non-flag argument. Getting
  # this wrong wrote the critical section to /dev/null and the tests failed
  # on an empty script rather than on the code.
  local out=""
  for a in "\$@"; do
    case "\$a" in -*) : ;; *) out="\$a"; break ;; esac
  done
  if [ -n "\$out" ]; then cat > "\$out"; else cat > /dev/null; fi
}
chmod() { note "chmod \$*"; }
# `flock` is not on every machine that runs this suite, and the lock is not
# what these tests are about: run the critical section directly and record
# that the script asked for the lock at all.
flock() {
  local script=""
  local prev=""
  for a in "\$@"; do
    case "\$a" in
      -w) : ;;
      *.sh) script="\$a" ;;
    esac
    prev="\$a"
  done
  note "flock \$*"
  # Sourced, not run: a child process would not see the stubs above, so the
  # critical section would call the real systemctl and install.
  if [ -n "\$script" ]; then source "\$script" "\${@: -1}"; fi
}
''';
    final file = File('${dir.path}/s.sh')..writeAsStringSync(
      '$harness\n${script.replaceAll('/usr/local/bin', bin.path)}',
    );
    Process.runSync('bash', [file.path]);
    final f = File(log);
    return f.existsSync()
        ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : <String>[];
  }

  bool restored(List<String> log) =>
      log.any((l) => l.startsWith('install ') && l.contains('.previous'));

  group('the fleet/manual update script', () {
    final script = buildNodeSoftwareUpdateScript([
      NodeReleaseArtifact(
        component: NodeComponent.veilCli,
        releaseUrl: 'https://example.invalid/veil-cli',
        expectedSha256: 'a' * 64,
      ),
    ]);

    test('a restart that FAILS still rolls back', () {
      // The defect: `sudo systemctl restart` bare under `set -e`. A non-zero
      // return ended the shell here, so the restore below it — which reads
      // perfectly and is asserted by three other tests — had never run once.
      final log = runStubbed(script, restartFails: true);

      expect(log, isNotEmpty, reason: 'the script did not reach the harness');
      expect(
        log.any((l) => l.startsWith('systemctl restart')),
        isTrue,
        reason: 'the restart never happened, so this proves nothing',
      );
      expect(
        restored(log),
        isTrue,
        reason: 'the previous binary was never put back',
      );
    });

    test('a service that starts and then dies rolls back', () {
      // The other half: restart returns 0, and the service is briefly active
      // before exiting. Reported as healthy by an immediate check.
      final log = runStubbed(script, deadChecks: 99);

      expect(restored(log), isTrue);
    });

    test('a service that passes the first check and then exits rolls back', () {
      // systemd answers "active" the moment it has started the process. The
      // health loop breaks on that first yes, so without a second look after a
      // dwell a binary that dies immediately is reported as a good update.
      final log = runStubbed(script, aliveChecks: 1, deadChecks: 99);

      expect(restored(log), isTrue, reason: 'a dead service was called healthy');
    });

    test('a healthy restart does NOT roll back', () {
      // Vacuity guard. A script that restores unconditionally passes both
      // assertions above and undoes every successful update.
      final log = runStubbed(script);

      expect(log.any((l) => l.startsWith('systemctl restart')), isTrue);
      expect(restored(log), isFalse, reason: 'a good update was rolled back');
    });

    test('a backup that cannot be made stops the install', () {
      // `cp || true` swallowed a failed copy — a full disk, a read-only mount —
      // and carried on to overwrite the working binary with nothing to go back
      // to. The point of keeping a copy is that it is THERE.
      final log = runStubbed(script, backupFails: true);

      expect(
        log.any((l) => l.startsWith('install ') && !l.contains('.previous')),
        isFalse,
        reason: 'installed over the binary with no copy kept',
      );
    });
  });

  group('the unattended self-updater', () {
    // Same defect, same shape, and this one runs as a timer with nobody
    // watching — so a fleet that opted in goes down together.
    final script = buildNodeAutoUpdateScript(enabled: true);

    /// The updater is written to a file by the outer script; the harness runs
    /// the outer one, so the inner never executes. Pull it out and run that.
    String inner({bool withBinary = true}) {
      final lines = script.split('\n');
      final from = lines.indexWhere((l) => l.contains("<<'XVEIL_UPDATER'"));
      final to = lines.indexWhere((l) => l == 'XVEIL_UPDATER', from);
      expect(from, isNot(-1));
      expect(to, isNot(-1));
      final dir = Directory.systemTemp.createTempSync('xveil-bin');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bin = File('${dir.path}/veil-cli');
      if (withBinary) {
        bin.writeAsStringSync('#!/usr/bin/env bash\necho "veil-cli 0.1.0"\n');
        Process.runSync('chmod', ['+x', bin.path]);
      }
      // The only substitution: the updater names an absolute path, and a
      // shell function cannot stand in for one. Everything else runs as
      // written.
      return lines
          .sublist(from + 1, to)
          .join('\n')
          .replaceFirst('BIN=/usr/local/bin/veil-cli', 'BIN=${bin.path}')
          // /run/lock is not writable here, and the lock is not what this
          // test is about.
          .replaceFirst(
            RegExp(r'LOCK=\S+'),
            'LOCK=${dir.path}/lock',
          );
    }

    test('a restart that FAILS still rolls back', () {
      final log = runStubbed(inner(), restartFails: true);

      expect(
        log.any((l) => l.startsWith('systemctl restart')),
        isTrue,
        reason: 'the restart never happened, so this proves nothing',
      );
      expect(restored(log), isTrue);
    });

    test('a healthy restart does NOT roll back', () {
      final log = runStubbed(inner());

      expect(restored(log), isFalse);
    });

    test('a clean install that does not come back restores nothing', () {
      // There is no previous binary on a repair, so there is nothing to go
      // back to. Attempting it anyway ends the run on a missing source and
      // reports the wrong thing — a failed rollback instead of a failed
      // install.
      final log = runStubbed(inner(withBinary: false), restartFails: true);

      expect(
        restored(log),
        isFalse,
        reason: 'tried to restore a binary that never existed',
      );
    });

    test('a node whose binary is missing REPAIRS itself', () {
      // report15 X15-M9. The updater promises to repair a broken install, and
      // `node_auto_update_test` asserts that an unknown running version does
      // not block an update — against the comparator function, not against the
      // script. In the script, `have="v$("$BIN" --version | awk …)"` under
      // `pipefail` and `errexit` ends the run before anything is downloaded,
      // and the unconditional `cp -a "$BIN" "$BIN.previous"` ends it again.
      //
      // So a node that most needs the updater is the one it cannot help.
      final log = runStubbed(inner(withBinary: false));

      expect(
        log.any((l) => l.startsWith('install ') && !l.contains('.previous')),
        isTrue,
        reason: 'the repair never reached the install',
      );
    });
  });

  group('two updaters must not interleave', () {
    // The timer and the fleet screen install the SAME binary and keep the same
    // `.previous` copy beside it. Without a shared lock they interleave, and
    // the loser's rollback restores a binary over the one the winner just
    // started - a rollback of somebody else's success (report15 X15-M13).
    final fleet = buildNodeSoftwareUpdateScript([
      NodeReleaseArtifact(
        component: NodeComponent.veilCli,
        releaseUrl: 'https://example.invalid/veil-cli',
        expectedSha256: 'a' * 64,
      ),
    ]);
    final auto = buildNodeAutoUpdateScript(enabled: true);

    test('both paths take the same lock', () {
      expect(fleet, contains(kVeilUpdateLockPath));
      expect(auto, contains(kVeilUpdateLockPath));
      // Naming the path is not taking the lock. The first version of this
      // asserted only the former, and replacing the timer's `flock` with
      // `false` left it green.
      expect(fleet, contains('flock -w'));
      expect(auto, contains('flock -w'));
      expect(auto, contains(r'exec 9>'));
    });

    test('the fleet script holds it across install AND rollback', () {
      // Not merely mentioned: the install has to happen INSIDE the section the
      // lock covers, or the lock is decoration.
      final log = runStubbed(fleet, restartFails: true);

      final locked = log.indexWhere((l) => l.startsWith('flock'));
      final installed = log.indexWhere(
        (l) => l.startsWith('install ') && !l.contains('.previous'),
      );
      final restored = log.indexWhere(
        (l) => l.startsWith('install ') && l.contains('.previous'),
      );
      expect(locked, isNot(-1), reason: 'nothing took the lock');
      expect(installed, greaterThan(locked), reason: 'installed unlocked');
      expect(restored, greaterThan(locked), reason: 'rolled back unlocked');
    });

    test('the download happens OUTSIDE it', () {
      // A lock held across a network fetch blocks the other path for as long
      // as the release server feels like taking.
      final log = runStubbed(fleet);
      final fetched = log.indexWhere((l) => l.startsWith('curl'));
      final locked = log.indexWhere((l) => l.startsWith('flock'));

      expect(fetched, isNot(-1));
      expect(locked, isNot(-1));
      expect(fetched, lessThan(locked));
    });

    test('a timer that cannot get the lock is not a failed unit', () {
      // Reporting failure every time somebody else is updating teaches whoever
      // runs the box to ignore the unit.
      expect(auto, contains('another update holds the lock'));
      final at = auto.indexOf('another update holds the lock');
      expect(auto.substring(at, at + 200), contains('exit 0'));
    });
  });

  group('a plan that went stale', () {
    // Check records what each node runs; Apply happens later. In between, the
    // timer or another administrator can update the same machine — and a plan
    // built before that would put its older cached version back, undoing fixes
    // and restarting the service to do it (report15 X15-M12).
    String planned({required String expected, required String target}) =>
        buildNodeSoftwareUpdateScript(
          [
            NodeReleaseArtifact(
              component: NodeComponent.veilCli,
              releaseUrl: 'https://example.invalid/veil-cli',
              expectedSha256: 'a' * 64,
            ),
          ],
          expectedVeilVersion: expected,
          targetVeilVersion: target,
        );

    /// The script with a `veil-cli` that reports [running].
    List<String> run(String script, String running) {
      final dir = Directory.systemTemp.createTempSync('xveil-ver');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bin = Directory('${dir.path}/bin')..createSync();
      File('${bin.path}/veil-cli')
        ..writeAsStringSync('#!/bin/sh\necho "veil-cli $running"\n')
        ..parent.path;
      Process.runSync('chmod', ['+x', '${bin.path}/veil-cli']);
      return runStubbed(
        script.replaceAll('/usr/local/bin', bin.path),
        binaryInstalled: false,
      );
    }

    bool installed(List<String> log) => log.any(
      (l) => l.startsWith('install ') && !l.contains('.previous'),
    );

    test('a node that still runs what was checked is updated', () {
      expect(
        installed(run(planned(expected: '0.8.0', target: '0.8.1'), '0.8.0')),
        isTrue,
        reason: 'the ordinary case was refused',
      );
    });

    test('a node somebody already moved is REFUSED', () {
      expect(
        installed(run(planned(expected: '0.8.0', target: '0.8.1'), '0.9.0')),
        isFalse,
        reason: '0.9.0 was overwritten with the plan\'s cached 0.8.1',
      );
    });

    test('and so is a target that is not newer than what runs', () {
      // Belt and braces for the case where the expected version happens to
      // match but the tag does not move forward — a resolver answering with an
      // older release, which is the reason the floor exists elsewhere.
      expect(
        installed(run(planned(expected: '0.9.0', target: '0.8.1'), '0.9.0')),
        isFalse,
      );
      expect(
        installed(run(planned(expected: '0.9.0', target: '0.9.0'), '0.9.0')),
        isFalse,
        reason: 'reinstalling the same version restarts the service for nothing',
      );
    });
  });

  group('turning the unattended updater off', () {
    final off = buildNodeAutoUpdateScript(enabled: false);

    test('the door is closed before anyone waits for the run inside', () {
      // Two orderings were wrong before this one. Disabling the timer AROUND a
      // running update let a root mutation land after the operator asked for
      // it to stop (report15 X15-M10). Stopping the SERVICE first stopped that
      // run — with a TERM, mid-install — and left the timer free to start
      // another one while the check was going on (report16 XV-10).
      //
      // Against the COMMANDS, not the words: the comment above these lines
      // explains what the old ordering did, and matching that compared the
      // check against its own explanation.
      expectBefore(
        off,
        'sudo systemctl stop $kAutoUpdateUnit.timer',
        'systemctl is-active --quiet $kAutoUpdateUnit.service',
      );
      expectBefore(off, 'sudo systemctl stop $kAutoUpdateUnit.timer', 'sudo rm -f');
    });

    test('and the run in flight is waited out, never killed', () {
      // A TERM to a running oneshot lands in the middle of a
      // copy-install-health transaction. Waiting is what keeps the binary
      // whole; refusing to say "disabled" is what keeps the record true.
      expect(
        off,
        isNot(contains('systemctl stop $kAutoUpdateUnit.service')),
        reason: 'the update in flight is killed mid-install',
      );
      expect(off, contains('was not stopped'));
    });

    test('and being killed anyway puts the old binary back', () {
      // Defence in depth for the TERM that arrives from somewhere else. The
      // trap is armed only after there IS a copy to go back to, and taken down
      // once the install is confirmed.
      final on = buildNodeAutoUpdateScript(enabled: true);

      // The restore trap by its own text: `trap ` alone matches the staging
      // cleanup several lines above and compared the wrong pair.
      const armed = "trap 'install -o root";
      expectBefore(on, r'cp -a "$BIN" "$BIN.previous"', armed);
      expectBefore(on, armed, 'trap - TERM INT');
    });

    test('and a run that will not stop is reported, not papered over', () {
      expect(off, contains('was not stopped'));
      final at = off.indexOf('was not stopped');
      expect(off.substring(at, at + 120), contains('exit 1'));
    });
  });

  group('a machine veil publishes no build for', () {
    test('is refused when the switch is turned on, not at the first tick', () {
      // The inner updater prints "unsupported architecture" and exits 0 every
      // tick, so systemd reported a healthy timer and the switch showed ON
      // while no update was ever applied.
      final on = buildNodeAutoUpdateScript(enabled: true);
      // The OUTER script's check, which is the first of the two: the inner
      // updater has one of its own for choosing a triple, and that one is the
      // late answer this replaces.
      expect(on, contains('were NOT enabled'));
      expectBefore(
        on,
        r'case "$(uname -m)"',
        'sudo systemctl enable --now',
      );
      expectBefore(on, 'were NOT enabled', 'sudo tee $kAutoUpdateScriptPath');
    });

    /// The outer script's architecture check, run as shell.
    ({int code, String stderr}) decide(String machine) {
      final lines = buildNodeAutoUpdateScript(enabled: true).split('\n');
      final from = lines.indexWhere((l) => l.startsWith(r'case "$(uname -m)"'));
      expect(from, isNot(-1), reason: 'the check moved');
      final to = lines.indexOf('esac', from);
      final result = Process.runSync('bash', [
        '-c',
        'set -euo pipefail\n'
            'uname() { echo "$machine"; }\n'
            '${lines.sublist(from, to + 1).join('\n')}\n'
            'echo ENABLED',
      ]);
      return (code: result.exitCode, stderr: result.stderr.toString());
    }

    test('and the refusal is a refusal, not a line of text', () {
      // Asserting that the check EXISTS is not asserting that it refuses:
      // replacing its arms with a catch-all left the first version of this
      // green.
      final refused = decide('armv7l');
      expect(refused.code, isNot(0));
      expect(refused.stderr, contains('were NOT enabled'));

      // Vacuity guard: the machines it does publish for still go through.
      for (final ok in ['x86_64', 'amd64', 'aarch64', 'arm64']) {
        expect(decide(ok).code, 0, reason: ok);
      }
    });
  });
}
