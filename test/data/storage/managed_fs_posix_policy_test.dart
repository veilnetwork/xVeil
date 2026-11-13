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
