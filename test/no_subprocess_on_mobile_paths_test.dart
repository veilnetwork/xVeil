import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// iOS cannot start a subprocess. At all.
///
/// `Process.run` there does not fail the way a missing binary fails — it throws
/// `ProcessException: Starting new processes is not supported on iOS` before it
/// looks at anything. Every such call on a path a phone reaches is therefore
/// not a fallback, not a best effort and not a slow way of doing the job: it is
/// an exception, and whatever the catch block does becomes the platform's
/// behaviour.
///
/// Three sites had it, and all three did something worse than nothing:
///
///   * `lib/debug/soak_hook.dart` ran `chmod 600` on the debug key, caught the
///     throw, deleted the key and reported "not listening" — so the debug
///     control plane could never arm on iOS on any build, which cost a whole
///     test sweep before anyone looked at why;
///   * `lib/data/veil_stack.dart` kept `Process.run('chmod', …)` as the
///     "fallback" for a host with no libc binding, i.e. for exactly the hosts
///     where it throws;
///   * `lib/data/runtime_dir_sweep.dart` ran `kill -0` and treated the throw as
///     "that pid is alive", which on Windows (no `kill` binary either) meant
///     every stale runtime directory was kept forever.
///
/// Each one now goes through libc — `posixChmod`, `posixProcessAlive` — which
/// is in the process already and cannot be substituted through PATH, the point
/// audit C-01 made for the same reason.
///
/// This check is deliberately STRUCTURAL. The defect is an absence of platform
/// support: no unit test can summon iOS, and a behavioural test on a Mac would
/// pass against the broken code because `chmod` exists there. What can be
/// asserted is that the call is not written on that path at all.
void main() {
  /// Files under `lib/` that may start a process, and why a phone never gets
  /// there. A new entry here is a claim about reachability — make it true.
  const desktopOnly = <String, String>{
    'lib/features/chat/chat_screen.dart':
        'opens a saved file with the OS handler, inside if (isMacOS/isLinux/'
            'isWindows); mobile falls through to showing the path',
    'lib/features/spaces/space_post_media.dart':
        'same OS-handler open, same three-way desktop guard',
    'lib/features/calls/screen_capture_permission.dart':
        'returns false unless Platform.isMacOS before it runs /usr/bin/open',
    'lib/data/vpn/linux_managed_vpn_backend.dart': 'Linux backend',
    'lib/data/vpn/windows_managed_vpn_backend.dart': 'Windows backend',
    'lib/data/vpn/privileged_launch_guard.dart':
        'the Process.run is inside WindowsPathSecurityProbe; the POSIX probe '
            'reads its facts through libc lstat',
    'lib/data/node/veil_node.dart':
        'drives the veil-cli BINARY, which only exists on the desktop '
            'config-file dev path (XVEIL_VEIL_CLI); mobile boots the node '
            'in-process',
    'lib/data/node/process_launcher.dart':
        'spawns that same veil-cli binary for SubprocessNodeController',
  };

  /// The three that were wrong. Named, so that a regression in any one of them
  /// fails with the reason rather than as an anonymous allowlist miss.
  const mustStayClean = <String>[
    'lib/debug/soak_hook.dart',
    'lib/data/veil_stack.dart',
    'lib/data/runtime_dir_sweep.dart',
    'lib/core/posix_file_facts.dart',
  ];

  final subprocess = RegExp(r'Process\.(run|runSync|start|killPid)\s*\(');

  List<String> callSitesIn(File file) {
    final out = <String>[];
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Prose about the trap is not the trap: all four files above document
      // why `Process.run` is the wrong tool, in comments.
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
      if (!subprocess.hasMatch(line)) continue;
      out.add('${file.path}:${i + 1}: ${line.trim()}');
    }
    return out;
  }

  test('the files that iOS reaches do not start processes', () {
    final offenders = <String>[];
    for (final path in mustStayClean) {
      offenders.addAll(callSitesIn(File(path)));
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'on iOS these throw "Starting new processes is not supported on '
          'iOS" — use posixChmod / posixProcessAlive from '
          'lib/core/posix_file_facts.dart:\n${offenders.join('\n')}',
    );
  });

  test('nothing else under lib/ grows one unnoticed', () {
    // The shape repeats, which is the actual lesson: three sites had it
    // independently. A fourth must not be able to appear without somebody
    // stating, here, why a phone cannot reach it.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (desktopOnly.containsKey(entity.path)) continue;
      offenders.addAll(callSitesIn(entity));
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'either this cannot run on iOS/Android — then say so in the '
          'desktopOnly map above — or it can, and it has to go through libc:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the scan can actually match, and the allowlist is not stale', () {
    // A source scan that finds nothing proves nothing on its own: the same
    // empty list comes back from a walk that visited no files or a regex that
    // can never fire. Point it at the files claimed to HAVE the calls.
    final missing = <String>[];
    for (final entry in desktopOnly.entries) {
      final file = File(entry.key);
      if (!file.existsSync() || callSitesIn(file).isEmpty) {
        missing.add(entry.key);
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'these are excused from the scan but no longer contain a call it '
          'would catch — either the regex stopped matching (and this whole '
          'file is inert) or the exemption is dead and should go:\n'
          '${missing.join('\n')}',
    );
  });
}
