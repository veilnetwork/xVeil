import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
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
  // Audit X-01. The pointer the migration threw away.
  // ─────────────────────────────────────────────────────────────────────────
  group('the profile an upgrade inherits', () {
    test('is still the same one on the SECOND launch, not just the first', () async {
      // The install being reproduced: the choice is where it has always been —
      // the system store — and the file pointer does not exist yet.
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
            'flutter.proxy_routing.private': 'PRIVATE-EXIT',
          });
      final systemStore = SharedPreferencesStorePlatform.instance;

      // FIRST launch after the upgrade. This one was never in doubt: the
      // pointer is still readable, so the right profile is picked.
      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {},
        ),
        'private',
      );
      expect(
        await systemStore.getAll(),
        isEmpty,
        reason: 'the system store must still be emptied — that is the leak',
      );

      // SECOND launch. A new process, and the system store the first launch
      // emptied. THIS is the finding: with the pointer left uncarried there is
      // nothing on disk to read, and the app comes up on `default` — a
      // different identity, a different posture, and an onboarding screen.
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(const {});
      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {},
        ),
        'private',
        reason: 'the second launch must land where the first one did',
      );

      // And the settings went with it rather than to the default profile.
      final installed = await SharedPreferencesStorePlatform.instance.getAll();
      expect(installed['flutter.proxy_routing'], 'PRIVATE-EXIT');
    });

    test('is recorded in the file pointer, once, before anything is erased', () async {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
          });
      await installProfilePreferences(
        supportDir: support.path,
        args: const [],
        environment: const {},
      );
      expect(await readRememberedProfile(support.path), 'private');
    });

    test('a --profile flag runs elsewhere WITHOUT taking the choice with it', () async {
      // Both halves in one launch: the flag decides this run, and the pointer
      // that the clear is about to destroy is still carried across untouched.
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
          });

      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const ['--profile', 'lab'],
          environment: const {},
        ),
        'lab',
      );
      expect(
        await readRememberedProfile(support.path),
        'private',
        reason: 'a one-shot flag must never become the remembered choice',
      );

      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(const {});
      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {},
        ),
        'private',
        reason: 'the next flag-less launch goes back to what the user chose',
      );
    });

    test('XVEIL_PROFILE is one-shot too and rewrites no pointer', () async {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
          });

      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {AppProfiles.envVar: 'lab'},
        ),
        'lab',
      );
      expect(
        await readRememberedProfile(support.path),
        'private',
        reason: 'an environment variable is an instruction, not a choice',
      );
    });

    test('an existing file pointer is never overwritten by the old one', () async {
      await writeRememberedProfile(support.path, 'decoy');
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
          });

      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {},
        ),
        'decoy',
      );
      expect(
        await readRememberedProfile(support.path),
        'decoy',
        reason: 'the file pointer is the newer record of the two',
      );
    });

    test('says WHICH source decided, so the caller can tell them apart', () {
      expect(
        AppProfiles.resolveWithSource(
          args: const ['--profile', 'lab'],
          environment: const {AppProfiles.envVar: 'env'},
          pointer: 'ptr',
          legacyPointer: 'old',
        ).source,
        ProfileSource.argument,
      );
      expect(
        AppProfiles.resolveWithSource(
          environment: const {AppProfiles.envVar: 'env'},
          pointer: 'ptr',
          legacyPointer: 'old',
        ).source,
        ProfileSource.environment,
      );
      expect(
        AppProfiles.resolveWithSource(
          environment: const {},
          pointer: 'ptr',
          legacyPointer: 'old',
        ).source,
        ProfileSource.newPointer,
      );
      final legacy = AppProfiles.resolveWithSource(
        environment: const {},
        legacyPointer: 'old',
      );
      expect(legacy.source, ProfileSource.legacyPointer);
      expect(legacy.name, 'old');
      expect(
        AppProfiles.resolveWithSource(environment: const {}).source,
        ProfileSource.fallbackDefault,
      );
      // An unusable legacy pointer is not a source at all, so nothing is
      // carried and the store may be emptied.
      expect(
        AppProfiles.resolveWithSource(
          environment: const {},
          legacyPointer: '../escape',
        ).source,
        ProfileSource.fallbackDefault,
      );
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

    test('of the carried pointer also stops the system store being emptied', () async {
      // X-01 and X-02 meeting: if the pointer cannot be recorded, clearing the
      // store would forget which profile this install runs on.
      blockWritesTo(activeProfilePath(support.path));
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData({
            'flutter.${AppProfiles.activePref}': 'private',
            'flutter.proxy_routing.private': 'PRIVATE-EXIT',
          });
      final systemStore = SharedPreferencesStorePlatform.instance;

      expect(
        await installProfilePreferences(
          supportDir: support.path,
          args: const [],
          environment: const {},
        ),
        'private',
      );
      expect(
        (await systemStore.getAll())['flutter.${AppProfiles.activePref}'],
        'private',
        reason:
            'without the pointer anywhere on disk, the old store is the only '
            'thing that still knows the answer',
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

  /// FAIL-CLOSED, and the assertion is about WHICH store is active — not about
  /// whether an error was reported.
  ///
  /// The install ends, on its last line, with the assignment that swaps the
  /// backend. Everything before it is file work that a platform can refuse. In
  /// `main` that was wrapped in "never fatal" and nothing else, so a refusal
  /// left `SharedPreferencesStorePlatform.instance` at the plugin default —
  /// i.e. the system store, i.e. iCloud, encrypted backups, and profile names
  /// glued into key names. One failed mkdir undid audit XV-16 in full.
  group('when the install cannot be done', () {
    /// The system store as the plugin leaves it: a sentinel that must NEVER be
    /// what a failed install settles on.
    final systemStore = _SystemStoreStandIn();

    setUp(() => SharedPreferencesStorePlatform.instance = systemStore);

    test('the active store is NOT the system one', () async {
      final errors = <Object>[];
      final profile = await installProfilePreferencesOrFallback(
        // Exactly how this fails in the field: path_provider has no answer on
        // this platform, so the directory lookup throws before any of the
        // install runs.
        supportDir: () async => throw MissingPluginException('no path_provider'),
        args: const [],
        onError: (e, _) => errors.add(e),
      );

      final active = SharedPreferencesStorePlatform.instance;
      expect(
        identical(active, systemStore),
        isFalse,
        reason:
            'a failed install must not leave the process writing its posture '
            'into the platform store — that is the leak XV-16 closed',
      );
      expect(active, isA<InMemorySharedPreferencesStore>());
      expect(await active.getAll(), isEmpty);
      expect(profile, AppProfiles.defaultName);
      expect(errors, hasLength(1), reason: 'the failure is still reported');
    });

    test('what is written afterwards does not reach the system store', () async {
      await installProfilePreferencesOrFallback(
        supportDir: () async => throw MissingPluginException('no path_provider'),
        args: const [],
      );
      await SharedPreferencesStorePlatform.instance.setValue(
        'String',
        'flutter.vpn_routing_policy',
        '{"apps":["org.example.app"]}',
      );
      expect(
        await systemStore.getAll(),
        isEmpty,
        reason: 'the routing policy is posture, and it must not go to backup',
      );
    });

    test('a SUCCESSFUL install still gets the real file store', () async {
      final profile = await installProfilePreferencesOrFallback(
        supportDir: () async => support.path,
        args: const [],
      );
      expect(profile, AppProfiles.defaultName);
      expect(
        SharedPreferencesStorePlatform.instance,
        isA<ProfilePreferencesStore>(),
        reason: 'the fallback must not be what every launch ends up on',
      );
    });

    test('the fallback never displaces a file store already installed', () async {
      await installProfilePreferencesOrFallback(
        supportDir: () async => support.path,
        args: const [],
      );
      final installed = SharedPreferencesStorePlatform.instance;
      installEphemeralPreferences();
      expect(identical(SharedPreferencesStorePlatform.instance, installed), isTrue);
    });
  });
}

/// Stands in for whatever the plugin registered — `NSUserDefaults` on iOS. The
/// point of the group above is that this object is not what a failed install
/// leaves behind.
class _SystemStoreStandIn extends InMemorySharedPreferencesStore {
  _SystemStoreStandIn() : super.empty();
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
