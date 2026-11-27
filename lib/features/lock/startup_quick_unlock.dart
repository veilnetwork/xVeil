import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../core/local_authentication.dart';
import '../../state/app_controller.dart';
import '../../state/identity_guard.dart';
import '../../state/providers.dart' show prefsProvider;
import '../../state/startup_unlock.dart';
import '../../state/storage_router_providers.dart';
import 'pattern_pad.dart';

class StartupQuickUnlock extends ConsumerStatefulWidget {
  const StartupQuickUnlock({super.key});
  @override
  ConsumerState<StartupQuickUnlock> createState() => _StartupQuickUnlockState();
}

class _StartupQuickUnlockState extends ConsumerState<StartupQuickUnlock> {
  bool _busy = false;
  String? _failure;

  Future<void> _unlock({int? grid, List<int> nodes = const []}) async {
    if (_busy) return;
    final lease = ref.leaseIdentity();
    final app = ref.read(appControllerProvider.notifier);
    final vault = ref.read(quickUnlockVaultProvider);
    final locator = ref.read(storageAccessLocatorProvider);
    final l = AppL10n.of(context);
    final authentication = ref.read(localScreenAuthenticationProvider);
    final system = grid == null;
    authentication.lastFailure = null;
    bool stillLocked() =>
        mounted &&
        ref.holdsIdentity(lease) &&
        ref.read(storageAccessLocatorProvider) == locator &&
        ref.read(appControllerProvider).phase == AppPhase.locked;
    String failureMessage(LocalAuthenticationFailure? failure) =>
        switch (failure) {
          LocalAuthenticationFailure.cancelled => l.quickUnlockAuthCancelled,
          LocalAuthenticationFailure.notEnrolled =>
            l.quickUnlockAuthNotEnrolled,
          LocalAuthenticationFailure.lockedOut => l.quickUnlockAuthLockedOut,
          LocalAuthenticationFailure.unavailable => l.quickUnlockUnavailable,
          LocalAuthenticationFailure.failed => l.quickUnlockAuthFailed,
          null => l.startupUnlockFailed,
        };
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (!stillLocked()) return;
      String? password;
      // Showing the methods grants no consent and does not inspect the vault.
      if (startupUnlockConsented(prefs, locator)) {
        password = system
            ? await vault.openSystem(l.quickUnlockReason)
            : await vault.openPattern(nodes, grid: grid);
      }
      if (!stillLocked()) return;
      if (password == null) {
        setState(
          () => _failure = failureMessage(
            system ? authentication.lastFailure : null,
          ),
        );
      } else {
        await app.unlock(password);
      }
    } catch (error) {
      if (stillLocked()) {
        final failure = error is PlatformException
            ? switch (error.code) {
                'authentication_cancelled' =>
                  LocalAuthenticationFailure.cancelled,
                'authentication_not_enrolled' =>
                  LocalAuthenticationFailure.notEnrolled,
                'authentication_locked' => LocalAuthenticationFailure.lockedOut,
                'unavailable' => LocalAuthenticationFailure.unavailable,
                _ => null,
              }
            : classifyLocalAuthenticationFailure(error);
        setState(() => _failure = failureMessage(failure));
      }
    } finally {
      if (mounted) {
        ref.invalidate(startupUnlockOptionsProvider);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _unlock(),
            icon: const Icon(Icons.fingerprint),
            label: Text(l.quickUnlockSystem),
          ),
          UnlockPattern(
            enabled: !_busy,
            submit: (grid, nodes) => _unlock(grid: grid, nodes: nodes),
          ),
          if (_failure case final failure?)
            Text(
              failure,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
