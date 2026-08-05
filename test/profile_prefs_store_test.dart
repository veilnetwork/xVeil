import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/state/identity_scoped_prefs.dart';

Map<String, Object?> _fileEntries(String path) {
  final raw = File(path);
  if (!raw.existsSync()) return {};
  final json = jsonDecode(raw.readAsStringSync()) as Map<String, dynamic>;
  return (json['e'] as Map<String, dynamic>).map(
    (k, v) => MapEntry(k, (v as Map<String, dynamic>)['v']),
  );
}

void main() {
  late Directory support;
  late SharedPreferencesStorePlatform original;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('xveil-prefs');
    original = SharedPreferencesStorePlatform.instance;
  });

  tearDown(() async {
    SharedPreferencesStorePlatform.instance = original;
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  group('the preference file', () {
    test('round-trips every value type the app stores', () async {
      final path = profilePrefsPath(support.path, AppProfiles.defaultName);
      final store = await ProfilePreferencesStore.load(path);
      await store.setValue('String', 'flutter.locale', 'ru');
      await store.setValue('Bool', 'flutter.onboarded', true);
      await store.setValue('Int', 'flutter.chat_page', 40);
      await store.setValue('Double', 'flutter.scale', 2.0);
      await store.setValue('StringList', 'flutter.apps', <String>['a', 'b']);

      final reopened = await ProfilePreferencesStore.load(path);
      final all = await reopened.getAll();
      expect(all['flutter.locale'], 'ru');
      expect(all['flutter.onboarded'], true);
      expect(all['flutter.chat_page'], 40);
      // A double that happens to be integral must not come back an int — the
      // cast in getDouble would throw somewhere far from here.
      expect(all['flutter.scale'], isA<double>());
      expect(all['flutter.apps'], <String>['a', 'b']);
    });

    test('a Double written as a whole number still reads back double', () async {
      // The type tag, not the JSON shape, decides. `2` and `2.0` are the same
      // number to a parser; `getDouble` on an int throws a cast error far from
      // wherever the value was written.
      final path = profilePrefsPath(support.path, AppProfiles.defaultName);
      File(path).writeAsStringSync(
        '{"v":1,"e":{"flutter.scale":{"t":"Double","v":2}}}',
      );
      final store = await ProfilePreferencesStore.load(path);
      expect((await store.getAll())['flutter.scale'], isA<double>());
    });

    test('lives inside the profile directory, one file each', () async {
      final real = await ProfilePreferencesStore.load(
        profilePrefsPath(support.path, AppProfiles.defaultName),
      );
      await real.setValue('String', 'flutter.vpn_routing_policy', 'REAL');

      final decoy = await ProfilePreferencesStore.load(
        profilePrefsPath(support.path, 'decoy'),
      );
      expect(
        (await decoy.getAll())['flutter.vpn_routing_policy'],
        isNull,
        reason: 'the decoy must not inherit the real profile posture',
      );

      await decoy.setValue('String', 'flutter.vpn_routing_policy', 'DECOY');
      expect(
        File('${support.path}/profiles/decoy/xveil.prefs.json').existsSync(),
        isTrue,
      );
      // ...and writing on one side does not reach the other.
      expect((await real.getAll())['flutter.vpn_routing_policy'], 'REAL');
      expect(
        _fileEntries(
          '${support.path}/xveil.prefs.json',
        )['flutter.vpn_routing_policy'],
        'REAL',
      );
    });

    test('key names carry no profile name', () async {
      final decoy = await ProfilePreferencesStore.load(
        profilePrefsPath(support.path, 'decoy'),
      );
      await decoy.setValue('String', 'flutter.proxy_routing', 'direct');

      final keys = _fileEntries(
        '${support.path}/profiles/decoy/xveil.prefs.json',
      ).keys;
      expect(keys, contains('flutter.proxy_routing'));
      expect(
        keys.where((k) => k.contains('decoy')),
        isEmpty,
        reason: 'a key list that names profiles IS a roster of them',
      );
    });

    test('a posture value one profile writes is invisible to the other', () async {
      // End to end through the real key helper: what a controller actually
      // calls, against the store `installProfilePreferences` installs.
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(const {});
      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const ['--profile', 'decoy'],
        ),
        'decoy',
      );
      await SharedPreferencesStorePlatform.instance.setValue(
        'String',
        'flutter.${identityScopedPrefKey('vpn_routing_policy')}',
        'DECOY-ONLY',
      );

      final keys = _fileEntries(
        '${support.path}/profiles/decoy/xveil.prefs.json',
      ).keys;
      expect(keys, contains('flutter.vpn_routing_policy'));
      expect(
        keys.where((k) => k.contains('decoy')),
        isEmpty,
        reason: 'the profile name must not be spelled into the key',
      );

      // Relaunch on the real profile: it must see nothing the decoy wrote.
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(const {});
      await installProfilePreferences(supportDir: support.path, args: const []);
      final real = await SharedPreferencesStorePlatform.instance.getAll();
      expect(real['flutter.vpn_routing_policy'], isNull);
    });

    test('a truncated file is an empty store, not a failed launch', () async {
      final path = profilePrefsPath(support.path, AppProfiles.defaultName);
      File(path).writeAsStringSync('{"v":1,"e":{"flutter.a":');
      final store = await ProfilePreferencesStore.load(path);
      expect(await store.getAll(), isEmpty);
      await store.setValue('String', 'flutter.a', 'again');
      expect((await store.getAll())['flutter.a'], 'again');
    });
  });

  group('the active profile pointer', () {
    test('is a file, and refuses a name this build would not accept', () async {
      expect(await readRememberedProfile(support.path), isNull);
      await writeRememberedProfile(support.path, 'decoy');
      expect(await readRememberedProfile(support.path), 'decoy');
      expect(File('${support.path}/xveil.profile').existsSync(), isTrue);

      File('${support.path}/xveil.profile').writeAsStringSync('../escape');
      expect(await readRememberedProfile(support.path), isNull);
    });
  });

  group('migration off the system store', () {
    test('moves each value to its profile and EMPTIES the old store', () async {
      // What an existing install looks like: everything in one system store,
      // with the profile glued onto the key.
      Directory('${support.path}/profiles/decoy').createSync(recursive: true);
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.profile.active.v1': 'default',
            'flutter.proxy_routing': 'REAL-EXIT',
            'flutter.vpn_routing_policy': '{"apps":["org.real.app"]}',
            'flutter.proxy_routing.decoy': 'DECOY-EXIT',
            'flutter.onboarded.decoy': true,
            'flutter.storage.lean_padding.v1': true,
          });
      final legacy = SharedPreferencesStorePlatform.instance;

      final profile = await installProfilePreferences(
        supportDir: support.path,
        args: const [],
      );
      expect(profile, AppProfiles.defaultName);

      final mine = _fileEntries('${support.path}/xveil.prefs.json');
      expect(mine['flutter.proxy_routing'], 'REAL-EXIT');
      expect(mine['flutter.vpn_routing_policy'], '{"apps":["org.real.app"]}');
      // A version suffix is not a profile suffix: `.v1` must survive intact.
      expect(mine['flutter.storage.lean_padding.v1'], true);
      expect(
        mine.keys.where((k) => k.contains('.decoy')),
        isEmpty,
        reason: 'the decoy keys belong to the decoy, not to this profile',
      );
      expect(mine['flutter.proxy_routing'], isNot('DECOY-EXIT'));

      final theirs = _fileEntries(
        '${support.path}/profiles/decoy/xveil.prefs.json',
      );
      expect(theirs['flutter.proxy_routing'], 'DECOY-EXIT');
      expect(theirs['flutter.onboarded'], true, reason: 'suffix stripped');

      // THE HALF THAT CLOSES THE LEAK. Copying alone leaves a second copy in
      // the store iOS backs up, which is the whole finding.
      expect(
        await legacy.getAll(),
        isEmpty,
        reason: 'the system store must be emptied, not merely read',
      );
    });

    test('the remembered profile decides which file is installed', () async {
      await writeRememberedProfile(support.path, 'decoy');
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.proxy_routing.decoy': 'DECOY-EXIT',
            'flutter.proxy_routing': 'REAL-EXIT',
          });

      final profile = await installProfilePreferences(
        supportDir: support.path,
        args: const [],
      );
      expect(profile, 'decoy');

      final installed = await SharedPreferencesStorePlatform.instance.getAll();
      expect(installed['flutter.proxy_routing'], 'DECOY-EXIT');
      expect(
        installed['flutter.proxy_routing'],
        isNot('REAL-EXIT'),
        reason: 'the decoy must not read the real profile through the store',
      );
    });

    test('an explicit --profile still wins and is not remembered', () async {
      await writeRememberedProfile(support.path, 'decoy');
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(const {});

      final profile = await installProfilePreferences(
        supportDir: support.path,
        args: const ['--profile', 'lab'],
      );
      expect(profile, 'lab');
      expect(
        await readRememberedProfile(support.path),
        'decoy',
        reason: 'a one-shot flag must not rewrite what the user chose',
      );
    });

    test('a value already in the file is not overwritten by the old one', () async {
      final path = profilePrefsPath(support.path, AppProfiles.defaultName);
      final existing = await ProfilePreferencesStore.load(path);
      await existing.setValue('String', 'flutter.proxy_routing', 'NEW');
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.proxy_routing': 'STALE',
          });

      await installProfilePreferences(supportDir: support.path, args: const []);

      final installed = await SharedPreferencesStorePlatform.instance.getAll();
      expect(installed['flutter.proxy_routing'], 'NEW');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Audit X-02. A write that says it worked when it did not.
  // ─────────────────────────────────────────────────────────────────────────
  group('a write that did not land', () {
    // A rename onto a DIRECTORY cannot succeed, which is the same shape of
    // refusal a full disk or a read-only mount produces — and unlike either of
    // those it can be arranged on demand.
    void blockWritesTo(String path) =>
        Directory(path).createSync(recursive: true);

    test('is reported to the caller, not swallowed', () async {
      final path = profilePrefsPath(support.path, AppProfiles.defaultName);
      blockWritesTo(path);
      final store = await ProfilePreferencesStore.load(path);

      expect(
        await store.setValue('String', 'flutter.proxy_routing', 'EXIT'),
        isFalse,
        reason: 'every mutator used to return true no matter what happened',
      );
      expect(await store.remove('flutter.proxy_routing'), isFalse);
      expect(await store.clear(), isFalse);
    });

    test('leaves the system store ALONE instead of erasing the only copy', () async {
      // The decoy's destination cannot be written, so its settings exist
      // nowhere else yet. Emptying the source here is data loss, and the
      // settings lost are the ones that decide how a container is opened.
      blockWritesTo('${support.path}/profiles/decoy/xveil.prefs.json');
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.proxy_routing': 'REAL-EXIT',
            'flutter.proxy_routing.decoy': 'DECOY-EXIT',
          });
      final systemStore = SharedPreferencesStorePlatform.instance;

      await installProfilePreferences(
        supportDir: support.path,
        args: const [],
        environment: const {},
      );

      expect(
        (await systemStore.getAll())['flutter.proxy_routing.decoy'],
        'DECOY-EXIT',
        reason: 'the only remaining copy must survive a failed migration',
      );
    });

    test('a system store that refuses to clear keeps the copies it made', () async {
      SharedPreferencesStorePlatform.instance = _RefusesToClear({
        'flutter.proxy_routing': 'REAL-EXIT',
      });

      await installProfilePreferences(
        supportDir: support.path,
        args: const [],
        environment: const {},
      );

      // The old code awaited `clear()` and logged success whatever it returned.
      // Nothing can force a store to comply, but the migration must not lose
      // the values over it either.
      expect(
        _fileEntries('${support.path}/xveil.prefs.json')['flutter.proxy_routing'],
        'REAL-EXIT',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Audit X-04. The suffix that matched first instead of longest.
  // ─────────────────────────────────────────────────────────────────────────
  group('routing a suffixed key to its profile', () {
    test('takes the LONGEST profile name, not the first one that fits', () {
      const known = {'default', 'a', 'x.a'};
      expect(
        routeLegacyKey('proxy_routing.x.a', known),
        (owner: 'x.a', key: 'proxy_routing'),
      );
      expect(
        routeLegacyKey('proxy_routing.a', known),
        (owner: 'a', key: 'proxy_routing'),
      );
      // Still not a profile just because it ends in a dot-something.
      expect(
        routeLegacyKey('storage.lean_padding.v1', known),
        (owner: 'default', key: 'storage.lean_padding.v1'),
      );
    });

    test('does not hand `x.a` settings to profile `a`', () async {
      Directory('${support.path}/profiles/a').createSync(recursive: true);
      Directory('${support.path}/profiles/x.a').createSync(recursive: true);
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.proxy_routing.x.a': 'X-A-EXIT',
            'flutter.proxy_routing.a': 'A-EXIT',
          });

      await installProfilePreferences(
        supportDir: support.path,
        args: const [],
        environment: const {},
      );

      final xa = _fileEntries('${support.path}/profiles/x.a/xveil.prefs.json');
      final a = _fileEntries('${support.path}/profiles/a/xveil.prefs.json');
      expect(xa['flutter.proxy_routing'], 'X-A-EXIT');
      expect(a['flutter.proxy_routing'], 'A-EXIT');
      expect(
        a.keys,
        isNot(contains('flutter.proxy_routing.x')),
        reason: 'matching `.a` first invents that key and files it under `a`',
      );
      expect(
        a.values,
        isNot(contains('X-A-EXIT')),
        reason: 'one profile routing policy must not arrive in another',
      );
    });

    test('reads a directory name the way the host writes paths', () {
      // What `Directory.listSync` hands back on Windows. Splitting on `/`
      // returned the whole string, so no profile was ever recognised there and
      // every suffixed value migrated into the default profile.
      expect(
        lastPathSegment(
          r'C:\Users\me\AppData\Roaming\xveil\profiles\decoy',
          windows: true,
        ),
        'decoy',
      );
      // Windows accepts both separators.
      expect(lastPathSegment(r'C:\xveil/profiles/decoy', windows: true), 'decoy');
      expect(
        lastPathSegment('/home/me/.local/share/xveil/profiles/decoy'),
        'decoy',
      );
      // ...and on POSIX a backslash is an ordinary character in a name, so
      // splitting on it there would invent a segment.
      expect(lastPathSegment(r'/tmp/xveil/a\b', windows: false), r'a\b');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Audit X-05. Who else on this machine can read the posture.
  // ─────────────────────────────────────────────────────────────────────────
  group('the files on disk', () {
    final skipReason = Platform.isWindows || !posixFactsAvailable
        ? 'POSIX modes are not the access boundary on this host'
        : null;

    test('are owner-only, and so is the directory holding them', () async {
      final path = profilePrefsPath(support.path, 'decoy');
      final store = await ProfilePreferencesStore.load(path);
      expect(
        await store.setValue('String', 'flutter.vpn_routing_policy', 'POSTURE'),
        isTrue,
      );

      expect(posixLstat(path)?.permissions, 0x180, reason: '0600');
      expect(
        posixLstat('${support.path}/profiles/decoy')?.permissions,
        0x1C0,
        reason: '0700',
      );
      expect(
        posixLstat(path)?.groupOrOtherWritable,
        isFalse,
        reason: 'another local user must not be able to rewrite the posture',
      );
    }, skip: skipReason);

    test('include the active-profile pointer, which names the identity', () async {
      expect(await writeRememberedProfile(support.path, 'decoy'), isTrue);
      expect(
        posixLstat(activeProfilePath(support.path))?.permissions,
        0x180,
        reason: 'which profile is in use is the fact most worth hiding',
      );
    }, skip: skipReason);

    test('are renamed into place, leaving no temporary behind', () async {
      expect(await writeRememberedProfile(support.path, 'decoy'), isTrue);
      expect(
        File('${activeProfilePath(support.path)}.tmp').existsSync(),
        isFalse,
      );
      expect(await readRememberedProfile(support.path), 'decoy');
    });

    test('are never written THROUGH a symlink planted at the temporary', () async {
      final victim = File('${support.path}/somebody-elses-file')
        ..writeAsStringSync('untouched');
      Link(
        '${activeProfilePath(support.path)}.tmp',
      ).createSync(victim.path);

      expect(await writeRememberedProfile(support.path, 'decoy'), isTrue);
      expect(
        victim.readAsStringSync(),
        'untouched',
        reason: 'the write must land in our own file, not down the link',
      );
      expect(await readRememberedProfile(support.path), 'decoy');
    }, skip: skipReason);
  });
}

/// A system store that accepts everything and clears nothing — the case the old
/// migration reported as a success because it never looked at the answer.
class _RefusesToClear extends InMemorySharedPreferencesStore {
  _RefusesToClear(super.data) : super.withData();

  @override
  Future<bool> clear() async => false;

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async => false;
}
