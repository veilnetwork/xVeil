/// At-rest protection. Network encryption does not depend on this choice.
///
/// This is the target storage contract, separate from the legacy onboarding
/// flag, which never selected a different persistence adapter.
enum StorageProtection {
  /// A password reveals one space, without a public directory of other spaces.
  hidden,

  /// One encrypted store per visible identity. Its existence is public locally.
  encrypted,

  /// One store per visible identity, with no encryption of its local contents.
  unencrypted;

  static const defaultForNewIdentity = encrypted;

  bool get hasPublicCatalogEntry => this != hidden;
}
