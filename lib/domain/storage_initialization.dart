/// An authenticated store may be initialized only if it contains no user
/// records. This capability never discovers other identities or erases data.
abstract interface class StorageInitializationSource {
  Future<bool> initializationIsBlank();
}

const kPendingIdentitySetupSetting = 'storage.pending_identity.v1';

/// Read-only replay admission. Chunk logs may include unreferenced staging
/// records; other application data and unrecognized settings refuse replay.
abstract interface class StorageSetupInspectionSource {
  Future<bool> setupHasOnlyBootstrapData({
    required Set<String> files,
    required Set<String> settings,
  });
}

/// Unknown nonempty stages also refuse ordinary boot/edit paths. Only the
/// explicitly supported journal stages may authorize recovery itself.
bool identitySetupIsPending(String? stage) =>
    stage != null && stage.isNotEmpty && stage != '0';
