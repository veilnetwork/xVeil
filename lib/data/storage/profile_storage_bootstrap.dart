import 'storage.dart';
import 'managed_directory_catalog.dart';
import 'managed_fs_platform.dart';
import 'profile_storage_router.dart';
import 'profile_storage_router_owner.dart';

typedef ManagedProfileBootstrap = ({
  bool erasurePending,
  ProfileStorageRouterOwner? owner,
});

/// No ordinary router, identity facade or OS-vault read is admitted for an
/// unfinished wipe. This inspection is only a hint; native admission remains
/// authoritative if publication races the initial inspection.
Future<ManagedProfileBootstrap> bootstrapManagedProfile({
  required String profileDirectory,
  required Storage Function() legacyFactory,
  ManagedFsPlatform inspectionFs = const ManagedFsPlatform(),
}) async {
  bool pending() => StorageProfileCoordinator.hasErasureIntent(
    profileDirectory,
    fs: inspectionFs,
  );
  if (pending()) return (erasurePending: true, owner: null);
  final ProfileStorageRouter router;
  try {
    router = await ProfileStorageRouter.open(
      profileDirectory: profileDirectory,
      legacyFactory: legacyFactory,
    );
  } catch (_) {
    if (pending()) return (erasurePending: true, owner: null);
    rethrow;
  }
  return (
    erasurePending: false,
    owner: ProfileStorageRouterOwner(
      router,
      reopen: () => ProfileStorageRouter.open(
        profileDirectory: profileDirectory,
        legacyFactory: legacyFactory,
      ),
    ),
  );
}
