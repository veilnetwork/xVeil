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
/// Two failures at once: the decoy BEHAVES like the real identity, which is
/// what anyone comparing them would look at; and the values sit in plaintext in
/// the preference store, where a forensic tool reads the real profile's posture
/// without opening a container at all.
void main() {
  final original = app.activeProfile;
  tearDown(() => app.activeProfile = original);

  test('a non-default profile gets its own key', () {
    app.activeProfile = 'decoy';
    final scoped = identityScopedPrefKey('vpn_routing_policy');

    expect(scoped, isNot('vpn_routing_policy'));
    expect(scoped, contains('decoy'));
  });

  test('two profiles never collide', () {
    app.activeProfile = 'alpha';
    final a = identityScopedPrefKey('proxy_routing');
    app.activeProfile = 'beta';
    final b = identityScopedPrefKey('proxy_routing');

    expect(
      a,
      isNot(b),
      reason: 'one profile answering for another is the whole finding',
    );
  });

  test('the default profile keeps the bare key', () {
    // Migration: an existing single-profile install must keep every setting it
    // had. Only a NEW profile starts from the code default — which is the
    // intended behaviour, not a loss: a decoy should not begin life wearing the
    // real profile's posture.
    app.activeProfile = AppProfiles.defaultName;
    expect(identityScopedPrefKey('notifications_preview'),
        'notifications_preview');
  });
}
