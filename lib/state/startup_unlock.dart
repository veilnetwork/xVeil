import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/local_authentication.dart';
import '../core/quick_unlock_vault.dart';
import '../data/storage/app_profile.dart';
import 'providers.dart';

const kStartupUnlockOptIn = 'quick_unlock_os_store.v1';

final quickUnlockSecretStoreProvider = Provider<QuickUnlockSecretStore>(
  (_) => const QuickUnlockSecretStore(),
);
final quickUnlockVaultProvider = Provider<QuickUnlockVault>((ref) {
  final path = ref.watch(deniableBootProvider)?.storePath ?? activeProfile;
  final scope = sha256.convert(utf8.encode('$activeProfile:$path')).toString();
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
