import 'identity_scoped_prefs.dart';

/// Non-secret storage tuning preferences kept in platform prefs rather than in
/// the deniable space, because they must be known before opening the container.
/// Profile-scoped (audit XV-10). This decides HOW the container is opened —
/// whether chunk padding is applied — so it is consulted before any container
/// exists to hold it, and a decoy inheriting the real profile's choice would
/// produce a container with a matching on-disk shape.
String get kStorageLeanPaddingPref =>
    identityScopedPrefKey('storage.lean_padding.v1');

/// Default to lower growth: this does not reveal plaintext and does not drop
/// hidden spaces. Users can turn it off for stronger file-size-change masking.
const bool kStorageLeanPaddingDefault = true;
