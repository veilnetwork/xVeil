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
