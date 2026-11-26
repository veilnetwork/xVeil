import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../core/local_authentication.dart';
import 'package:flutter/services.dart';
import '../../state/app_controller.dart';
import '../../state/identity_guard.dart';
import '../../state/startup_unlock.dart';
import '../../state/storage_router_providers.dart';
import 'pattern_pad.dart';

class StartupQuickUnlock extends ConsumerStatefulWidget {
  const StartupQuickUnlock({super.key});
  @override
  ConsumerState<StartupQuickUnlock> createState() => _StartupQuickUnlockState();
}

class _StartupQuickUnlockState extends ConsumerState<StartupQuickUnlock> {
  List<int> _nodes = [];
  int _padEpoch = 0;
  bool _busy = false;
  String? _failure;

  Future<void> _unlock(bool system) async {
    if (_busy) return;
    final lease = ref.leaseIdentity();
    final app = ref.read(appControllerProvider.notifier);
    final vault = ref.read(quickUnlockVaultProvider);
    final locator = ref.read(storageAccessLocatorProvider);
    final l = AppL10n.of(context);
    final authentication = ref.read(localScreenAuthenticationProvider);
    authentication.lastFailure = null;
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
      final password = system
          ? await vault.openSystem(l.quickUnlockReason)
          : await vault.openPattern(_nodes);
      if (!mounted ||
          ref.read(storageAccessLocatorProvider) != locator ||
          !ref.holdsIdentity(lease) ||
          ref.read(appControllerProvider).phase != AppPhase.locked) {
        return;
      }
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
      if (mounted && ref.holdsIdentity(lease)) {
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
        setState(() {
          _busy = false;
          _nodes = [];
          _padEpoch++;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(startupUnlockOptionsProvider).asData?.value;
    final l = AppL10n.of(context);
    if (options == null || !options.enabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          if (options.system)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _unlock(true),
              icon: const Icon(Icons.fingerprint),
              label: Text(l.quickUnlockSystem),
            ),
          if (options.grid != null && !options.patternBlocked)
            ExpansionTile(
              title: Text(l.quickUnlockPattern),
              children: [
                PatternPad(
                  key: ValueKey('startup-pattern-$_padEpoch'),
                  grid: options.grid!,
                  onChanged: (v) => _nodes = v,
                ),
                TextButton(
                  onPressed: _busy ? null : () => _unlock(false),
                  child: Text(l.quickUnlockWithPattern),
                ),
              ],
            ),
          if (options.patternBlocked) Text(l.startupUnlockBlocked),
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
