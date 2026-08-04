import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
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
}
