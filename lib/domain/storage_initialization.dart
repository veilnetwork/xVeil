/// An authenticated store may be initialized only if it contains no user
/// records. This capability never discovers other identities or erases data.
abstract interface class StorageInitializationSource {
  Future<bool> initializationIsBlank();
}

const kPendingIdentitySetupSetting = 'storage.pending_identity.v1';
