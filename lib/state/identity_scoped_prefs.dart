import '../data/storage/app_profile.dart';
import '../main.dart' show activeProfile;

/// Profile-scoped key for a preference that describes a SECURITY POSTURE.
///
/// ## Why these cannot simply stay global
///
/// `shared_preferences` is per-APP, and the deniable design runs several
/// profiles out of one installation. A globally-keyed setting is therefore
/// shared by all of them — so the decoy profile inherited the real one's VPN
/// app list, its proxy exit, whether previews are shown and whether every
/// identity stays online (audit XV-10).
///
/// That is a deniability failure twice over. The decoy BEHAVES like the real
/// identity, which is what someone comparing them would look at; and the values
/// sit in plaintext in the app's preference store, where a forensic tool reads
/// the real profile's posture without ever opening a container.
///
/// ## Why not encrypted per-space settings
///
/// The audit's preferred remedy, and right for the ones it can reach. But most
/// of this set is consulted BEFORE the container is open — the padding preset
/// decides how to open it, the proxy and VPN policy configure the node that
/// boots alongside it, and notification settings are read while locked. A
/// setting that chooses how to open the container cannot live inside it.
///
/// Profile scope is what is actually available at that point, and it closes the
/// half that matters most: one profile no longer answers for another.
///
/// ## Migration
///
/// The default profile keeps the bare key, exactly as [AppProfiles.scopedPrefKey]
/// does — so an existing single-profile install keeps every setting it had.
/// A non-default profile starts from the code default, which is the intended
/// behaviour: a decoy should not begin life wearing the real profile's posture.
String identityScopedPrefKey(String key) =>
    AppProfiles.scopedPrefKey(key, activeProfile);

/// Every profile-scoped posture key, for the paths that must clear them.
///
/// A wipe used to remove only `onboarded` and `storage_mode` (audit XV-15), so
/// "clear all data" left the proxy exit, the VPN app list, CIDR and DNS, the
/// notification preview mode and the always-online choice sitting in the
/// preference store in plaintext. Someone who wiped because they had to still
/// had their network posture on disk, readable without a container.
///
/// A list rather than a prefix sweep: `shared_preferences` holds plenty that is
/// not ours to delete, and a wipe that guesses is a wipe that eventually
/// removes someone else's key. Adding a posture setting means adding it here,
/// which is the point — the compiler cannot notice, so the list has to be the
/// obvious place to look.
const kIdentityPosturePrefKeys = <String>[
  'proxy_routing',
  'vpn_routing_policy',
  'keep_all_online',
  'notifications_enabled',
  'notifications_preview',
  'storage.lean_padding.v1',
  'whisper.auto_fetch.v1',
];

/// Whether this profile has agreed to the speech model being fetched on its
/// own, without being asked at the time.
///
/// Default absent, which means NO. The model is ~57 MiB from a public CDN, and
/// fetching it the moment a session opens told that CDN this device runs
/// xVeil, from this IP, at this minute — with a traffic shape distinctive
/// enough to recognise again (audit XV-05). For an app built so that its use
/// leaves as little trace as possible, that is the wrong thing to do
/// unprompted.
///
/// Set by the deliberate offer in Settings or under a voice message: tapping
/// Download IS the agreement, so nobody is asked twice for the same thing.
const kWhisperAutoFetchPrefKey = 'whisper.auto_fetch.v1';
