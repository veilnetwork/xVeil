import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/local_authentication.dart';
import '../core/quick_unlock_vault.dart';
import '../data/storage/app_profile.dart';
import 'providers.dart';
import 'storage_router_providers.dart';
import '../domain/storage_locator.dart';
import '../core/storage_unlock_scope.dart';

const kStartupUnlockOptIn = 'quick_unlock_os_store.v1';

final quickUnlockSecretStoreProvider = Provider<QuickUnlockSecretStore>(
  (_) => const QuickUnlockSecretStore(),
);
final quickUnlockVaultProvider = Provider<QuickUnlockVault>((ref) {
  final locator = ref.watch(storageAccessLocatorProvider);
  final legacyPath =
      ref.watch(deniableBootProvider)?.storePath ?? activeProfile;
  final path = locator is LegacyStorageLocator
      ? legacyPath
      : ref.watch(profileStorageRouterProvider)?.profileDirectory ?? legacyPath;
  final scope = storageUnlockScope(activeProfile, path, locator);
  return QuickUnlockVault(
    ref.watch(quickUnlockSecretStoreProvider),
    scope,
    ref.watch(localScreenAuthenticationProvider),
  );
});
final startupUnlockOptionsProvider =
    FutureProvider.autoDispose<StartupUnlockOptions>((ref) async {
      final prefs = await ref.watch(prefsProvider.future);
      if (prefs.getBool(kStartupUnlockOptIn) != true) {
        return const StartupUnlockOptions();
      }
      try {
        return await ref.watch(quickUnlockVaultProvider).options();
      } catch (_) {
        return const StartupUnlockOptions();
      }
    });
