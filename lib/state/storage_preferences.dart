/// Non-secret storage tuning preferences kept in platform prefs rather than in
/// the deniable space, because they must be known before opening the container.
const String kStorageLeanPaddingPref = 'storage.lean_padding.v1';

/// Default to lower growth: this does not reveal plaintext and does not drop
/// hidden spaces. Users can turn it off for stronger file-size-change masking.
const bool kStorageLeanPaddingDefault = true;
