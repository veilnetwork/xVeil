import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/veil_stack.dart';

/// `runtime_dir` used to be taken as a finished directory: `chmod 700` was
/// applied to whatever it named and shutdown ran `delete(recursive: true)` on
/// it, with no check that it was ever ours. `/`, a home directory or a shared
/// `/run` in that field — a typo, a copied unit file, an env var set by
/// something else in the session — and a daemon running as root re-permissioned
/// it on the way up and emptied it on the way down (audit C-02).
///
/// These tests are the two halves that matter, and they are deliberately
/// written so that no bug in THEM can remove anything outside the temporary
/// root each one makes: nothing here calls `delete` on a path the test did not
/// create, and every lease is asserted to live under that root before it is
/// asked to release.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xveil-lease-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<RuntimeDirLease> leaseUnder(String base) async {
    final lease = await RuntimeDirLease.acquire(base);
    // Belt: everything below deletes only through the lease, and the lease
    // deletes only this path.
    expect(lease.path, startsWith(root.path));
    return lease;
  }

  group('the configured value is a base, never the directory we own', () {
    test('a fresh child is created under it, and only that is removed',
        () async {
      final base = Directory('${root.path}/run')..createSync();
      final bystander = File('${base.path}/somebody-elses.db')
        ..writeAsStringSync('precious');
      final neighbour = Directory('${base.path}/another-service')..createSync();
      File('${neighbour.path}/data').writeAsStringSync('also precious');

      final lease = await leaseUnder(base.path);
      expect(lease.path, isNot(base.path));
      expect(Directory(lease.path).existsSync(), isTrue);
      File('${lease.path}/admin.sock').writeAsStringSync('');

      expect(await lease.release(), isNull);

      expect(Directory(lease.path).existsSync(), isFalse,
          reason: 'the lease must remove what it created');
      expect(base.existsSync(), isTrue, reason: 'the base is not ours');
      expect(bystander.existsSync(), isTrue);
      expect(File('${neighbour.path}/data').readAsStringSync(),
          'also precious');
    });

    test('two leases under one base never collide', () async {
      final base = '${root.path}/run';
      final first = await leaseUnder(base);
      final second = await leaseUnder(base);
      expect(first.path, isNot(second.path));
      await first.release();
      expect(Directory(second.path).existsSync(), isTrue,
          reason: 'one lease released the other lease`s directory');
      await second.release();
    });

    test('a root or home directory is refused outright', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      for (final forbidden in <String>[
        '/',
        if (home != null && home.isNotEmpty) home,
        if (home != null && home.isNotEmpty) '$home/',
        '',
        '   ',
      ]) {
        // Deliberately NOT `expectLater(…, throwsA(…))`: these are real paths
        // on the machine running the suite, and a guard that has been broken
        // would create a directory in the developer's home with no handle left
        // to remove it. Taking the lease back means even a failing run cleans
        // up after itself — and the lease can only ever remove what it made.
        Object? error;
        RuntimeDirLease? escaped;
        try {
          escaped = await RuntimeDirLease.acquire(forbidden);
        } on Object catch (thrown) {
          error = thrown;
        }
        if (escaped != null) await escaped.release();
        expect(error, isA<RuntimeDirNotPrivate>(), reason: forbidden);
      }
    });

    test('the leased directory is owner-only from the moment it exists',
        () async {
      final lease = await leaseUnder('${root.path}/run');
      expect(Directory(lease.path).statSync().mode & 0x3F, 0);
      await lease.release();
    }, skip: Platform.isWindows ? 'POSIX modes only' : null);
  });

  group('release deletes what this lease made, and nothing else', () {
    test('a directory that lost our marker is left alone', () async {
      final lease = await leaseUnder('${root.path}/run');
      final keepsake = File('${lease.path}/keepsake')..writeAsStringSync('x');
      File('${lease.path}/$kRuntimeDirMarker').deleteSync();

      expect(await lease.release(), contains('marker'));
      expect(keepsake.existsSync(), isTrue,
          reason: 'a directory we cannot prove is ours must survive');
    });

    test('a directory carrying somebody else`s marker is left alone', () async {
      final lease = await leaseUnder('${root.path}/run');
      final other = await leaseUnder('${root.path}/run');
      // The marker of a DIFFERENT lease: the file is there, it says all the
      // right words, and the secret in it is not the one this lease wrote.
      File('${lease.path}/$kRuntimeDirMarker').writeAsStringSync(
        File('${other.path}/$kRuntimeDirMarker').readAsStringSync(),
      );

      expect(await lease.release(), contains('not the one this lease wrote'));
      expect(Directory(lease.path).existsSync(), isTrue);
      await other.release();
    });

    test('a different directory swapped in under the same name is left alone',
        () async {
      final lease = await leaseUnder('${root.path}/run');
      final secret = File('${lease.path}/$kRuntimeDirMarker').readAsStringSync();
      // The substitution the marker alone cannot catch: an impostor that CARRIES
      // our marker, moved into our path after we stopped looking. Only the
      // (device, inode) identity taken at creation can tell them apart.
      final impostor = Directory('${root.path}/impostor')..createSync();
      File('${impostor.path}/$kRuntimeDirMarker').writeAsStringSync(secret);
      File('${impostor.path}/not-ours').writeAsStringSync('leave me alone');
      Directory(lease.path).renameSync('${root.path}/moved-away');
      impostor.renameSync(lease.path);

      expect(await lease.release(), contains('different directory'));
      expect(File('${lease.path}/not-ours').existsSync(), isTrue);
    }, skip: posixFactsAvailable
        ? null
        : 'inode identity needs the POSIX fact layer');

    test('a path that is no longer a directory is left alone', () async {
      final lease = await leaseUnder('${root.path}/run');
      Directory(lease.path).deleteSync(recursive: true);
      File(lease.path).writeAsStringSync('not a directory any more');

      expect(await lease.release(), contains('no longer a directory'));
      expect(File(lease.path).existsSync(), isTrue);
    });

    test('a symlink pointing somewhere else is never followed', () async {
      final lease = await leaseUnder('${root.path}/run');
      final elsewhere = Directory('${root.path}/elsewhere')..createSync();
      final hostage = File('${elsewhere.path}/hostage')
        ..writeAsStringSync('do not delete me');
      Directory(lease.path).deleteSync(recursive: true);
      Link(lease.path).createSync(elsewhere.path);

      expect(await lease.release(), isNotNull);
      expect(hostage.existsSync(), isTrue,
          reason: 'a recursive delete followed a planted symlink');
    }, skip: Platform.isWindows ? 'symlink creation needs privileges' : null);

    test('releasing twice cannot take a re-created directory with it',
        () async {
      final lease = await leaseUnder('${root.path}/run');
      expect(await lease.release(), isNull);
      // Somebody else takes the freed name, as the OS is free to let them.
      final newcomer = Directory(lease.path)..createSync(recursive: true);
      final theirs = File('${newcomer.path}/theirs')..writeAsStringSync('x');

      expect(await lease.release(), 'already released');
      expect(theirs.existsSync(), isTrue);
    });

    test('a lease whose directory already vanished says so quietly', () async {
      final lease = await leaseUnder('${root.path}/run');
      Directory(lease.path).deleteSync(recursive: true);
      expect(await lease.release(), 'the directory is already gone');
    });
  });

  group('the refusal is decided before anything is deleted', () {
    test('refusalToRelease is null exactly when the directory is ours',
        () async {
      final lease = await leaseUnder('${root.path}/run');
      expect(lease.refusalToRelease(), isNull);
      File('${lease.path}/$kRuntimeDirMarker').writeAsStringSync('nothing');
      expect(lease.refusalToRelease(), isNotNull);
      // Still there: asking the question must not act on the answer.
      expect(Directory(lease.path).existsSync(), isTrue);
    });
  });
}
