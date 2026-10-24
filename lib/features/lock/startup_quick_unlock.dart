import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/identity_guard.dart';
import '../../state/startup_unlock.dart';
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
  bool _failed = false;

  Future<void> _unlock(bool system) async {
    if (_busy) return;
    final lease = ref.leaseIdentity();
    final app = ref.read(appControllerProvider.notifier);
    final vault = ref.read(quickUnlockVaultProvider);
    final reason = AppL10n.of(context).quickUnlockReason;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final password = system
          ? await vault.openSystem(reason)
          : await vault.openPattern(_nodes);
      if (!mounted ||
          !ref.holdsIdentity(lease) ||
          ref.read(appControllerProvider).phase != AppPhase.locked) {
        return;
      }
      if (password == null) {
        setState(() => _failed = true);
      } else {
        await app.unlock(password);
      }
    } catch (_) {
      if (mounted && ref.holdsIdentity(lease)) setState(() => _failed = true);
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
          if (_failed)
            Text(
              l.startupUnlockFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
