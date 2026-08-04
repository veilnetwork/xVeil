import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/state/device_settings_sync.dart';
import 'package:xveil/state/identity_scoped_prefs.dart';

/// The three device-SYNCED settings the audit found unscoped and unwiped.
const _synced = <String>[kSyncSignaturePolicy, kSyncLocale, kSyncShowReactions];

void main() {
  late Directory support;
  late SharedPreferencesStorePlatform original;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('xveil-scoped');
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.withData(const {});
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = original;
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  Future<SharedPreferencesStorePlatform> launchAs(String profile) async {
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.withData(const {});
    final resolved = await installProfilePreferences(
      supportDir: support.path,
      args: profile == AppProfiles.defaultName
          ? const []
          : ['--profile', profile],
    );
    expect(resolved, profile);
    return SharedPreferencesStorePlatform.instance;
  }

  test('the decoy does not inherit the real profile signature policy', () async {
    // The one with teeth: this setting decides whether the device answers a
    // "please sign this message" request WITHOUT asking. Inherited, the decoy
    // silently produces non-repudiable proof of authorship — in the app whose
    // premise is that authorship can be denied. No attacker required.
    final real = await launchAs(AppProfiles.defaultName);
    await real.setValue(
      'String',
      'flutter.${identityScopedPrefKey(kSyncSignaturePolicy)}',
      'auto',
    );

    final decoy = await launchAs('decoy');
    expect(
      (await decoy.getAll())['flutter.$kSyncSignaturePolicy'],
      isNull,
      reason: 'a decoy that auto-signs is not a decoy',
    );
    // ...and the real profile still has its own answer.
    final again = await launchAs(AppProfiles.defaultName);
    expect((await again.getAll())['flutter.$kSyncSignaturePolicy'], 'auto');
  });

  test('language and reactions do not cross either', () async {
    final real = await launchAs(AppProfiles.defaultName);
    await real.setValue(
      'String',
      'flutter.${identityScopedPrefKey(kSyncLocale)}',
      'ru',
    );
    await real.setValue(
      'Bool',
      'flutter.${identityScopedPrefKey(kSyncShowReactions)}',
      false,
    );

    final decoy = await launchAs('decoy');
    final seen = await decoy.getAll();
    expect(
      seen['flutter.$kSyncLocale'],
      isNull,
      reason: 'a decoy opening in the language the real profile chose is a tell',
    );
    expect(seen['flutter.$kSyncShowReactions'], isNull);
  });

  test('every synced setting is on the clear-everything list', () {
    for (final key in _synced) {
      expect(
        kIdentityPosturePrefKeys,
        contains(key),
        reason: '"$key" survives a wipe unless it is listed here',
      );
    }
  });

  test('"clear all data" leaves no per-profile setting behind', () async {
    final store = await launchAs(AppProfiles.defaultName);
    // Everything a controller persists per profile, written the way the
    // controllers write it.
    const written = <String, Object>{
      kSyncSignaturePolicy: 'auto',
      kSyncLocale: 'ru',
      kSyncShowReactions: false,
      'proxy_routing': 'exit-node',
      'vpn_routing_policy': '{"apps":["org.real.app"]}',
      'keep_all_online': true,
      'notifications_enabled': true,
      'notifications_preview': 'full',
      'storage.lean_padding.v1': true,
      'whisper.auto_fetch.v1': true,
    };
    for (final entry in written.entries) {
      await store.setValue(
        entry.value is bool ? 'Bool' : 'String',
        'flutter.${identityScopedPrefKey(entry.key)}',
        entry.value,
      );
    }
    expect(await store.getAll(), hasLength(written.length));

    // The wipe, exactly as AppController.startOver / wipeContainers run it.
    for (final key in kIdentityPosturePrefKeys) {
      await store.remove('flutter.${identityScopedPrefKey(key)}');
    }

    expect(
      await store.getAll(),
      isEmpty,
      reason: 'someone who wiped because they had to must not still have this',
    );
    // And it is gone from the FILE, not merely from a cache.
    final onDisk = await ProfilePreferencesStore.load(
      profilePrefsPath(support.path, AppProfiles.defaultName),
    );
    expect(await onDisk.getAll(), isEmpty);
  });
}
