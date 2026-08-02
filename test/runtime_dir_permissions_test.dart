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
  final posix = !Platform.isWindows;
  final skipReason = Platform.isWindows
      ? 'POSIX modes only; Windows uses ACLs and restrictRuntimeDir skips it'
      : null;

  test('the runtime directory is owner-only', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_rt_perms');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Start from something permissive so a no-op implementation cannot pass
    // by inheriting a strict umask from whoever runs the suite.
    await Process.run('chmod', ['755', dir.path]);

    await restrictRuntimeDir(dir.path);

    expect(
      dir.statSync().mode & 0x1FF,
      0x1C0, // 0700
      reason: 'group and other must not reach admin.sock',
    );
  }, skip: skipReason);

  test('a chmod that exits zero without working is caught', () async {
    // The audit's actual finding, and the one an exit-code check cannot see:
    // some filesystems (mounted shares, certain vendor mounts) ACCEPT the
    // chmod and keep the old mode. Injected here rather than described,
    // because a test that only exercises a chmod which really fails leaves the
    // read-back verification unproven — a version with the verification
    // deleted passed until this case existed.
    final dir = Directory.systemTemp.createTempSync('xveil_rt_lying');
    addTearDown(() => dir.deleteSync(recursive: true));
    await Process.run('chmod', ['755', dir.path]);

    Future<ProcessResult> lies(String _) async =>
        ProcessResult(0, 0, '', ''); // "success", changes nothing

    if (runtimeDirMustBePrivate()) {
      await expectLater(
        restrictRuntimeDir(dir.path, chmod: lies),
        throwsA(isA<RuntimeDirNotPrivate>()),
        reason: 'on a shared-filesystem platform this must fail closed',
      );
    } else {
      // Sandboxed platforms keep booting — the OS is the boundary there.
      await restrictRuntimeDir(dir.path, chmod: lies);
    }
    expect(dir.statSync().mode & 0x3F, isNot(0),
        reason: 'precondition: the injected chmod really did nothing');
  }, skip: skipReason);

  test('a chmod that cannot run at all is caught', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_rt_nochmod');
    addTearDown(() => dir.deleteSync(recursive: true));
    await Process.run('chmod', ['755', dir.path]);

    Future<ProcessResult> explodes(String _) async =>
        throw const ProcessException('chmod', <String>[], 'not found', 2);

    if (runtimeDirMustBePrivate()) {
      await expectLater(
        restrictRuntimeDir(dir.path, chmod: explodes),
        throwsA(isA<RuntimeDirNotPrivate>()),
      );
    } else {
      await restrictRuntimeDir(dir.path, chmod: explodes);
    }
  }, skip: skipReason);

  test('a symlink at the runtime path is refused, not followed', () async {
    // `Directory.create` follows a symlink, so a link planted at the runtime
    // path redirected the CONTROL socket into a directory the attacker owns.
    final root = Directory.systemTemp.createTempSync('xveil_rt_link');
    addTearDown(() => root.deleteSync(recursive: true));
    final elsewhere = Directory('${root.path}/elsewhere')..createSync();
    final linkPath = '${root.path}/runtime';
    Link(linkPath).createSync(elsewhere.path);

    await expectLater(
      createRestrictedRuntimeDir(linkPath),
      throwsA(isA<RuntimeDirNotPrivate>()),
    );
  }, skip: skipReason);

  test('a fresh runtime directory is created and secured in one call', () async {
    final root = Directory.systemTemp.createTempSync('xveil_rt_create');
    addTearDown(() => root.deleteSync(recursive: true));
    final target = '${root.path}/nested/runtime';

    await createRestrictedRuntimeDir(target);

    expect(Directory(target).existsSync(), isTrue);
    if (posix) {
      expect(Directory(target).statSync().mode & 0x3F, 0,
          reason: 'the directory must not be reachable by group or other');
    }
  }, skip: skipReason);
}
