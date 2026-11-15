import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/local_authentication.dart';
import '../core/startup_unlock_consent.dart';
export '../core/startup_unlock_consent.dart';
import '../core/quick_unlock_vault.dart';
import '../data/storage/app_profile.dart';
import 'providers.dart';
import 'storage_router_providers.dart';
import '../domain/storage_locator.dart';
import '../core/storage_unlock_scope.dart';
import '../data/storage/managed_directory_catalog.dart'
    show ManagedErasureRelease;

final quickUnlockSecretStoreProvider = Provider<QuickUnlockSecretStore>(
  (_) => const QuickUnlockSecretStore(),
);
final quickUnlockVaultProvider = Provider<QuickUnlockVault>((ref) {
  final locator = ref.watch(storageAccessLocatorProvider);
  return _storageVault(
    ref.watch(quickUnlockSecretStoreProvider),
    ref.watch(localScreenAuthenticationProvider),
    locator,
    ref.watch(deniableBootProvider)?.storePath ?? activeProfile,
    ref.watch(profileStorageRouterProvider)?.profileDirectory,
  );
});

QuickUnlockVault _storageVault(
  QuickUnlockSecretStore store,
  LocalScreenAuthentication authentication,
  IdentityStorageLocator locator,
  String legacyPath,
  String? managedPath,
) {
  final path = locator is LegacyStorageLocator
      ? legacyPath
      : managedPath ?? legacyPath;
  return QuickUnlockVault(
    store,
    storageUnlockScope(activeProfile, path, locator),
    authentication,
  );
}

/// Capture an explicit target without subscribing an ongoing identity edit to
/// provider changes. Uses exactly the ordinary entry namespace, no OS read.
QuickUnlockVault quickUnlockVaultForLocator(
  Ref ref,
  IdentityStorageLocator locator,
) {
  final router = ref.read(profileStorageRouterProvider);
  if (locator is ManagedStorageLocator && router == null) {
    throw StateError('Managed saved entry requires its profile context');
  }
  return _storageVault(
    ref.read(quickUnlockSecretStoreProvider),
    ref.read(localScreenAuthenticationProvider),
    locator,
    ref.read(deniableBootProvider)?.storePath ?? activeProfile,
    router?.profileDirectory,
  );
}

/// The enclosing profile wipe has durably finalized and actually closed its
/// coordinator. Old wrappers remain sealed; providers recreate owners only
/// after the receipt has atomically detached the verified retired scope set.
void admitFreshStartupUnlock(
  Ref ref,
  QuickUnlockRetirement retirement,
  ManagedErasureRelease receipt,
) {
  if (!ref.mounted) throw StateError('Saved-entry owner disposed');
  retirement.admitFreshLifetime(receipt);
  ref.invalidate(quickUnlockVaultProvider);
  ref.invalidate(startupUnlockOptionsProvider);
}

final startupUnlockOptionsProvider =
    FutureProvider.autoDispose<StartupUnlockOptions>((ref) async {
      final locator = ref.watch(storageAccessLocatorProvider);
      final vault = ref.watch(quickUnlockVaultProvider);
      final prefs = await ref.watch(prefsProvider.future);
      if (!startupUnlockConsented(prefs, locator)) {
        return const StartupUnlockOptions();
      }
      try {
        return await vault.options();
      } catch (_) {
        return const StartupUnlockOptions();
      }
    });
