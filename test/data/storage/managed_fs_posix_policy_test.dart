import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

void main() {
  PosixFileFacts facts(int uid, int gid, int permissions) => PosixFileFacts(
    deviceId: 1,
    inode: 2,
    uid: uid,
    gid: gid,
    mode: 0x4000 | permissions,
  );
  const current = 11000; // synthetic application UID
  test(
    'Android system-owned ancestors are accepted only as platform authorities',
    () {
      // These public UID/GID/modes were read from actual app-data ancestors.
      for (final f in [
        facts(1000, 1000, 0x1f9),
        facts(1000, 1000, 0x1c9),
        facts(0, 1000, 0x1ed),
      ]) {
        final android = managedPosixPathPolicy(
          f,
          currentUid: current,
          android: true,
        );
        expect(android.safeAncestor, isTrue);
        expect(android.ownedByCurrentUser, isFalse);
        expect(android.ownerOnly, isFalse);
      }
      expect(
        managedPosixPathPolicy(
          facts(1000, 1000, 0x1f9),
          currentUid: current,
        ).safeAncestor,
        isFalse,
      );
      expect(
        managedPosixPathPolicy(
          facts(current, current, 0x1c0),
          currentUid: current,
          android: true,
        ),
        (ownerOnly: true, ownedByCurrentUser: true, safeAncestor: true),
      );
    },
  );
  test('Android app-owned primary-group directories are stable ancestors', () {
    // Context.getFilesDir() creates 0771 under the application's own UID/GID.
    // The full UID includes the Android user offset; other profiles do not
    // share this grant. These remain non-private ancestors, never key files.
    for (final uid in [10000, 11000, 19999, 111000, 1011000]) {
      final result = managedPosixPathPolicy(
        facts(uid, uid, 0x1f9),
        currentUid: uid,
        android: true,
      );
      expect(result.safeAncestor, isTrue);
      expect(result.ownerOnly, isFalse);
      expect(result.ownedByCurrentUser, isTrue);
    }
  });
  test('the Android app-group exception does not admit other principals', () {
    for (final f in [
      facts(current, current + 1, 0x1f9),
      facts(current + 1, current, 0x1f9),
      facts(current, 3003, 0x1f9),
      facts(current, 50000, 0x1f9),
      facts(current, current, 0x1fb), // world-writable, without sticky bit
    ]) {
      expect(
        managedPosixPathPolicy(
          f,
          currentUid: current,
          android: true,
        ).safeAncestor,
        isFalse,
      );
    }
    expect(
      managedPosixPathPolicy(
        facts(current, current, 0x1f9),
        currentUid: current,
      ).safeAncestor,
      isFalse,
    );
    expect(
      managedPosixPathPolicy(
        facts(111000, 11000, 0x1f9),
        currentUid: 111000,
        android: true,
      ).safeAncestor,
      isFalse,
    );
    for (final uid in [9997, 20000, 50000, 90000, 109999, 120000]) {
      expect(
        managedPosixPathPolicy(
          facts(uid, uid, 0x1f9),
          currentUid: uid,
          android: true,
        ).safeAncestor,
        isFalse,
      );
    }
    final file = PosixFileFacts(
      deviceId: 1,
      inode: 2,
      uid: current,
      gid: current,
      mode: 0x8000 | 0x1b0,
    );
    final result = managedPosixPathPolicy(
      file,
      currentUid: current,
      android: true,
    );
    expect(result.safeAncestor, isFalse);
    expect(result.ownerOnly, isFalse);
  });
  test(
    'ordinary groups, foreign owners and non-sticky world writes remain unsafe',
    () {
      for (final f in [
        facts(1001, 1001, 0x1ed),
        facts(0, 1023, 0x1fd),
        facts(1000, 1000, 0x1ff),
      ]) {
        expect(
          managedPosixPathPolicy(
            f,
            currentUid: current,
            android: true,
          ).safeAncestor,
          isFalse,
        );
      }
      expect(
        managedPosixPathPolicy(
          facts(0, 0, 0x3ff),
          currentUid: current,
        ).safeAncestor,
        isTrue,
      );
      expect(
        managedPosixPathPolicy(
          facts(12345, 12345, 0x3ff),
          currentUid: current,
          android: true,
        ).safeAncestor,
        isFalse,
      );
    },
  );
}
