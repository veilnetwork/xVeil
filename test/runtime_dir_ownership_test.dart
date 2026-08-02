import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

/// The runtime base can come from `XVEIL_RUNTIME_DIR`, and lock/wipe removes the
/// claimed directory RECURSIVELY.
///
/// The first fix wrote the marker straight into whatever the variable named,
/// creating it if absent — so the marker proved "we were once pointed here",
/// not "we created this". Aimed at a directory that already held data, the very
/// next teardown removed it, using the marker we had just written as the
/// evidence it was ours (audit XV-09).
///
/// (The audit paired this with "reject existing/nonempty paths". That is
/// deliberately NOT taken: profiles and headless/bot deployments legitimately
/// run on an operator-chosen directory. The base is honoured; only the child is
/// owned.)
void main() {
  group('claiming a runtime directory', () {
    test('claims a fresh child and never the base itself', () async {
      final base = Directory.systemTemp.createTempSync('xveil_claim_base');
      addTearDown(() => base.deleteSync(recursive: true));
      // The base already holds data — the case that made this dangerous.
      final precious = File('${base.path}/important.txt')
        ..writeAsStringSync('do not delete me');

      final claimed = await claimRuntimeDirUnder(base.path, uniqueSuffix: '1');

      expect(
        claimed,
        isNot(base.path),
        reason: 'the operator-supplied base must never be the claimed dir',
      );
      expect(File(claimed).parent.path, base.path);
      expect(Directory(claimed).existsSync(), isTrue);
      expect(runtimeDirIsOurs(claimed), isTrue);
      expect(
        runtimeDirIsOurs(base.path),
        isFalse,
        reason: 'the base must NOT come away marked as ours',
      );
      expect(precious.existsSync(), isTrue);
    });

    test('never adopts a directory that already exists', () async {
      // A leftover from a dead run, or something planted at the predictable
      // name. Either way it was not created by this process, so it is not ours
      // to own — and therefore not ours to delete.
      final base = Directory.systemTemp.createTempSync('xveil_claim_taken');
      addTearDown(() => base.deleteSync(recursive: true));
      final squatted = Directory('${base.path}/xveil-rt-7')..createSync();
      File('${squatted.path}/someone-elses.txt').writeAsStringSync('data');

      final claimed = await claimRuntimeDirUnder(base.path, uniqueSuffix: '7');

      expect(claimed, isNot(squatted.path));
      expect(runtimeDirIsOurs(squatted.path), isFalse);
      expect(File('${squatted.path}/someone-elses.txt').existsSync(), isTrue);
      expect(runtimeDirIsOurs(claimed), isTrue);
    });

    test('refuses a base that is a symlink', () async {
      // `Directory.create` follows a symlink, so a link at the base would
      // relocate everything underneath it — including what teardown deletes.
      final root = Directory.systemTemp.createTempSync('xveil_claim_link');
      addTearDown(() => root.deleteSync(recursive: true));
      final elsewhere = Directory('${root.path}/elsewhere')..createSync();
      final linkPath = '${root.path}/base';
      Link(linkPath).createSync(elsewhere.path);

      await expectLater(
        claimRuntimeDirUnder(linkPath, uniqueSuffix: '1'),
        throwsA(isA<RuntimeDirNotPrivate>()),
      );
    }, skip: Platform.isWindows ? 'POSIX symlink semantics' : null);

    test('two claims under one base never collide', () async {
      final base = Directory.systemTemp.createTempSync('xveil_claim_twice');
      addTearDown(() => base.deleteSync(recursive: true));

      final a = await claimRuntimeDirUnder(base.path, uniqueSuffix: '9');
      final b = await claimRuntimeDirUnder(base.path, uniqueSuffix: '9');

      expect(a, isNot(b));
      expect(runtimeDirIsOurs(a), isTrue);
      expect(runtimeDirIsOurs(b), isTrue);
    });
  });

  group('marking a directory we made ourselves', () {
    test('a directory we created is recognised as ours', () async {
      final dir = Directory.systemTemp.createTempSync('xveil_own_yes');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(runtimeDirIsOurs(dir.path), isFalse,
          reason: 'precondition: an unmarked directory is not ours');
      await markRuntimeDirOwned(dir.path);
      expect(runtimeDirIsOurs(dir.path), isTrue);
    });

    test('marking refuses to CREATE the directory', () async {
      // The XV-09 hole in one line: a marker written into a directory we did
      // not create claims something that is not true.
      final missing =
          '${Directory.systemTemp.path}/xveil-never-made-${DateTime.now().microsecondsSinceEpoch}';

      await expectLater(
        markRuntimeDirOwned(missing),
        throwsA(isA<RuntimeDirNotPrivate>()),
      );
      expect(Directory(missing).existsSync(), isFalse);
    });

    test("someone else's directory is never ours", () async {
      final dir = Directory.systemTemp.createTempSync('xveil_own_no');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/important.txt').writeAsStringSync('do not delete me');
      Directory('${dir.path}/nested').createSync();

      expect(runtimeDirIsOurs(dir.path), isFalse);
    });

    test('a missing directory is not ours', () {
      // Answering "yes" here would make a caller's guard look like it passed.
      final missing =
          '${Directory.systemTemp.path}/xveil-does-not-exist-${DateTime.now().microsecondsSinceEpoch}';
      expect(runtimeDirIsOurs(missing), isFalse);
    });
  });
}
