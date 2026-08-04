import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/main.dart' as app;
import 'package:xveil/state/identity_scoped_prefs.dart';

/// `shared_preferences` is per-APP, and the deniable design runs several
/// profiles out of one installation — so a globally-keyed setting was shared by
/// all of them. The decoy profile inherited the real one's VPN app list, its
/// proxy exit, whether message previews are shown and whether every identity
/// stays online (audit XV-10).
///
/// That was first fixed by gluing the profile name onto the key
/// (`proxy_routing.<decoy>`), and this file used to assert exactly that. It is
/// now the opposite contract, and deliberately so (audit XV-16): a key list
/// carrying profile names ENUMERATED every profile on the device, in a store
/// iOS copies into iCloud backups — a roster of identities in an app whose
/// premise is that the second one cannot be shown to exist.
///
/// Separation moved to WHERE the preferences live: one file per profile, inside
/// that profile's own directory under Application Support, which is excluded
/// from backup. That half is proved in `profile_prefs_store_test.dart` ("a
/// posture value one profile writes is invisible to the other"). What is left
/// here is the half that must hold at the KEY: the name must be the same for
/// every profile, so it says nothing about which profiles exist.
void main() {
  final original = app.activeProfile;
  tearDown(() => app.activeProfile = original);

  test('the key is identical for every profile, and names none of them', () {
    const key = 'vpn_routing_policy';
    final seen = <String>{};
    for (final profile in [AppProfiles.defaultName, 'decoy', 'alpha', 'beta']) {
      app.activeProfile = profile;
      final scoped = identityScopedPrefKey(key);
      expect(
        scoped,
        key,
        reason: 'profile "$profile" must not move the key: separation lives in '
            'the file, and a moved key would be back to a roster',
      );
      expect(
        scoped,
        isNot(contains(profile == AppProfiles.defaultName ? 'default' : profile),
        ),
        reason: 'a backup that reads this key list must learn no profile name',
      );
      seen.add(scoped);
    }
    expect(seen, hasLength(1));
  });

  test('every posture key stays name-free under a decoy profile', () {
    app.activeProfile = 'decoy';
    for (final key in kIdentityPosturePrefKeys) {
      expect(identityScopedPrefKey(key), key, reason: key);
      expect(identityScopedPrefKey(key), isNot(contains('decoy')), reason: key);
    }
    // The list is the other half of the contract: it is what the wipe paths
    // walk, so a posture setting missing from it survives "clear all data".
    expect(kIdentityPosturePrefKeys, contains('proxy_routing'));
    expect(kIdentityPosturePrefKeys, contains('vpn_routing_policy'));
    expect(kIdentityPosturePrefKeys, contains('signature_policy'));
  });

  test('the default profile keeps the bare key', () {
    // Migration: an existing single-profile install must keep every setting it
    // had. Only a NEW profile starts from the code default — which is the
    // intended behaviour, not a loss: a decoy should not begin life wearing the
    // real profile's posture.
    app.activeProfile = AppProfiles.defaultName;
    expect(
      identityScopedPrefKey('notifications_preview'),
      'notifications_preview',
    );
  });
}
