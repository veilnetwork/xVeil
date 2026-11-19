import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_fs_windows.dart';

void main() {
  const current =
      'S-1-5-21-1-2-3-1001'; // synthetic, not an account on the stand
  Map<String, Object> rule(
    String sid,
    int rights, {
    bool allow = true,
    bool inheritOnly = false,
  }) => {
    'sid': sid,
    'rights': rights,
    'allow': allow,
    'inheritOnly': inheritOnly,
  };
  Object facts(List<Object> rules, {String owner = current}) => {
    'owner': owner,
    'rules': rules,
  };

  test('private current-user/system/admin grants are accepted', () {
    expect(
      managedWindowsAclPolicy(
        facts([
          rule(current, 0x10000000),
          rule('S-1-5-18', 0x10000000),
          rule('S-1-5-32-544', 0x10000000),
        ]),
        current,
      ),
      (
        ownerOnly: true,
        safeAncestor: true,
        ownedByCurrentUser: true,
        otherUsersHaveReadOnlyAccess: true,
      ),
    );
  });
  test(
    'foreign read grants fail privacy; ancestor delete/write grants fail stability',
    () {
      expect(
        managedWindowsAclPolicy(facts([rule('S-1-1-0', 0x120089)]), current),
        (
          ownerOnly: false,
          safeAncestor: true,
          ownedByCurrentUser: true,
          otherUsersHaveReadOnlyAccess: true,
        ),
      );
      for (final mask in [
        0x10000,
        0x40,
        0x40000,
        0x80000,
        0x10000000,
        0x40000000,
      ]) {
        expect(
          managedWindowsAclPolicy(
            facts([rule('S-1-1-0', mask)]),
            current,
          )!.safeAncestor,
          isFalse,
        );
      }
      expect(
        managedWindowsAclPolicy(
          facts([rule('S-1-1-0', 4)]),
          current,
        )!.safeAncestor,
        isTrue,
      );
    },
  );
  test('deny and inherit-only entries never grant access', () {
    expect(
      managedWindowsAclPolicy(
        facts([
          rule('S-1-1-0', 0x10000000, allow: false),
          rule('S-1-3-0', 0x10000000, inheritOnly: true),
        ]),
        current,
      )!.ownerOnly,
      isTrue,
    );
  });

  test(
    'preference repair rejects any foreign access that can change a file',
    () {
      const everyone = 'S-1-1-0';
      expect(
        managedWindowsAclPolicy(
          facts([rule(everyone, 0x1200a9)]),
          current,
        )!.otherUsersHaveReadOnlyAccess,
        isTrue,
      );
      for (final mask in [
        0x2, // write data
        0x4, // append data
        0x10, // write extended attributes
        0x100, // write attributes
        0x10000, // delete
        0x40000, // change DACL
        0x80000, // change owner
        0x10000000, // generic all
        0x40000000, // generic write
      ]) {
        expect(
          managedWindowsAclPolicy(
            facts([rule(everyone, mask)]),
            current,
          )!.otherUsersHaveReadOnlyAccess,
          isFalse,
          reason: 'foreign access mask $mask',
        );
      }
    },
  );
  test(
    'unknown owners and malformed/incomplete grants cannot establish privacy',
    () {
      expect(
        managedWindowsAclPolicy(
          facts([], owner: 'S-1-5-21-9-9-9-1001'),
          current,
        )!.ownedByCurrentUser,
        isFalse,
      );
      expect(
        managedWindowsAclPolicy(
          facts([], owner: 'S-1-5-21-9-9-9-1001'),
          current,
        )!.safeAncestor,
        isFalse,
      );
      for (final value in [
        null,
        {},
        {'error': 'fixture-only'},
        {
          'owner': current,
          'rules': [{}],
        },
        facts([
          {'allow': true, 'inheritOnly': false, 'sid': '', 'rights': 1},
        ]),
      ]) {
        expect(managedWindowsAclPolicy(value, current), isNull);
      }
      expect(managedWindowsAclPolicy(facts([]), ''), isNull);
    },
  );
  test(
    'native final-path comparison accepts separators but refuses another root',
    () {
      expect(
        managedWindowsFinalPathMatches(
          r'C:\fixture/storage',
          r'\\?\C:\fixture\storage',
        ),
        isTrue,
      );
      expect(
        managedWindowsFinalPathMatches(
          'C:/fixture/storage/',
          r'c:\fixture\storage',
        ),
        isTrue,
      );
      expect(
        managedWindowsFinalPathMatches(
          r'C:\fixture\storage',
          r'D:\fixture\storage',
        ),
        isFalse,
      );
      expect(
        managedWindowsFinalPathMatches(
          r'C:\fixture\storage',
          r'C:\fixture\other',
        ),
        isFalse,
      );
      expect(
        managedWindowsFinalPathMatches(
          r'\\host\share\storage',
          r'\\host\share\storage',
        ),
        isFalse,
      );
    },
  );
}
