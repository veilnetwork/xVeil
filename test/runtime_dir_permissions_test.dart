import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

/// The node's runtime directory holds `admin.sock` — the socket that CONTROLS
/// the node — alongside `app.sock` and the obfs4 PSK. It was created with a
/// plain `Directory.create`, which leaves it at the process umask: 0755 on a
/// typical desktop. On a shared machine that is another local user reaching the
/// admin endpoint of someone else's node.
///
/// (The audit that surfaced this framed it as PSK disclosure. That part is
/// weak — the same PSK ships inside every published APK, as release.yml says in
/// so many words. The control socket is the reason to care.)
void main() {
  test(
    'the runtime directory is owner-only',
    () async {
      final dir = Directory.systemTemp.createTempSync('xveil_rt_perms');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Start from something permissive so a no-op implementation cannot pass
      // by inheriting a strict umask from whoever runs the suite.
      await Process.run('chmod', ['755', dir.path]);

      await restrictRuntimeDir(dir.path);

      final mode = await Process.run('stat', ['-f', '%Lp', dir.path]);
      expect(
        (mode.stdout as String).trim(),
        '700',
        reason: 'group and other must not reach admin.sock',
      );
    },
    // POSIX modes only; Windows uses ACLs and restrictRuntimeDir skips it.
    skip: Platform.isWindows || Platform.isLinux
        ? 'stat -f is the BSD/macOS spelling'
        : null,
  );
}
