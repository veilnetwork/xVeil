/// Key for a preference that describes a SECURITY POSTURE.
///
/// ## Why these cannot simply be global
///
/// The deniable design runs several profiles out of one installation, and the
/// preference store used to be per-APP. A globally-keyed setting was therefore
/// shared by all of them — so the decoy profile inherited the real one's VPN
/// app list, its proxy exit, whether previews are shown and whether every
/// identity stays online (audit XV-10).
///
/// That is a deniability failure twice over. The decoy BEHAVES like the real
/// identity, which is what someone comparing them would look at; and the values
/// sat in plaintext in the app's preference store, where a forensic tool read
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
/// ## Why this is now the identity function
///
/// It used to glue the profile name onto the key (`proxy_routing.<decoy>`),
/// which separated the values and PUBLISHED the roster: the key list alone
/// enumerated every profile on the device, in a store iOS copies into iCloud
/// backups. Separation now comes from WHERE the preferences live — one file per
/// profile, inside that profile's own directory under Application Support,
/// which is excluded from backup (audit XV-16). The scoping this call
/// represents is real; it simply no longer needs to be spelled in the name.
///
/// Kept as a named call rather than deleted at every site: it is the marker
/// that says "this value is per profile, and it must not leak across", and the
/// list below is the other half of that contract.
String identityScopedPrefKey(String key) => key;

/// Every profile-scoped key, for the paths that must clear them.
///
/// A wipe used to remove only `onboarded` and `storage_mode` (audit XV-15), so
/// "clear all data" left the proxy exit, the VPN app list, CIDR and DNS, the
/// notification preview mode and the always-online choice sitting in the
/// preference store in plaintext. Someone who wiped because they had to still
/// had their network posture on disk, readable without a container.
///
/// The device-SYNCED settings were missed by the same fix and stayed behind for
/// the same reason (audit XV-15, again). The worst of them is the signature
/// policy: it decides whether this device answers a "please sign this" request
/// automatically, so an inherited "yes" makes a profile emit NON-REPUDIABLE
/// proof of authorship — in a messenger built so that authorship can always be
/// denied. Language and reaction visibility are milder but the same class: a
/// wipe that leaves the interface in the language the previous occupant chose
/// has not wiped what someone comparing two profiles would look at.
///
/// A list rather than a prefix sweep: the preference file holds plenty that is
/// not ours to delete, and a wipe that guesses is a wipe that eventually
/// removes someone else's key. Adding a setting means adding it here, which is
/// the point — the compiler cannot notice, so the list has to be the obvious
/// place to look.
const kIdentityPosturePrefKeys = <String>[
  'proxy_routing',
  'vpn_routing_policy',
  'keep_all_online',
  'notifications_enabled',
  'notifications_preview',
  'storage.lean_padding.v1',
  'whisper.auto_fetch.v1',
  // Device-synced settings. `kSync*` in device_settings_sync.dart holds the
  // same three strings; they are spelled out here rather than imported so this
  // list stays readable as the checklist it is.
  'signature_policy',
  'locale',
  'show_reactions',
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
