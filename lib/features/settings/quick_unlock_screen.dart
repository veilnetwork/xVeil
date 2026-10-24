import '../../state/providers.dart' show prefsProvider;
import '../../state/startup_unlock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_authentication.dart';
import '../../core/secure_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../state/identity_guard.dart';
import '../../state/app_controller.dart' show IdentityLease;
import '../../state/screen_lock_controller.dart';
import '../lock/pattern_pad.dart';

class QuickUnlockScreen extends ConsumerStatefulWidget {
  const QuickUnlockScreen({super.key});
  @override
  ConsumerState<QuickUnlockScreen> createState() => _QuickUnlockScreenState();
}

class _QuickUnlockScreenState extends ConsumerState<QuickUnlockScreen> {
  final _password = TextEditingController();
  late final IdentityLease _lease;
  int? _grid;
  bool _system = false;
  bool _busy = false;
  bool _startup = false;
  bool _startupTouched = false;
  String? _error;
  List<int> _first = [];
  List<int> _second = [];

  @override
  void initState() {
    super.initState();
    _lease = ref.leaseIdentity();
    final state = ref.read(screenLockProvider);
    _grid = state.patternGrid;
    _system = state.systemAuthentication;
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppL10n.of(context);
    if (_busy ||
        !ref.holdsIdentity(_lease) ||
        ref.read(startupUnlockOptionsProvider).asData == null) {
      return;
    }
    if ((_first.isNotEmpty || _second.isNotEmpty) &&
        (_first.length != _second.length ||
            List.generate(
              _first.length,
              (i) => _first[i] != _second[i],
            ).any((v) => v))) {
      setState(() => _error = l.quickUnlockMismatch);
      return;
    }
    final password = _password.text;
    final grid = _grid;
    final nodes = List<int>.unmodifiable(_first);
    final system = _system;
    final startupEnabled = _startup;
    if (startupEnabled && grid == null && !system) {
      setState(() => _error = l.quickUnlockSaveFailed);
      return;
    }
    final lease = ref.leaseIdentity();
    setState(() {
      _busy = true;
      _error = null;
    });
    var saved = false;
    try {
      saved = await ref
          .read(screenLockProvider.notifier)
          .configureQuickUnlock(
            password: password,
            grid: grid,
            nodes: nodes,
            clearPattern: grid == null,
            system: system,
            reason: l.quickUnlockReason,
          );
    } catch (_) {
      /* retain the form; no credentials in diagnostics */
    }
    if (!mounted || !ref.holdsIdentity(lease)) return;
    if (saved) {
      try {
        final vault = ref.read(quickUnlockVaultProvider);
        if (startupEnabled) {
          if (grid == null && !system) throw StateError('No unlock method');
          final prefs = await ref.read(prefsProvider.future);
          // Mark consent before touching the OS store, so crash/wipe can also
          // find a partially configured credential. No marker exists by default.
          if (!await prefs.setBool(kStartupUnlockOptIn, true)) {
            throw StateError('Consent not saved');
          }
          await ref
              .read(screenLockProvider.notifier)
              .duringSystemPrompt(
                () => vault.configure(
                  password: password,
                  grid: grid,
                  nodes: nodes,
                  system: system,
                  stillCurrent: () => mounted && ref.holdsIdentity(lease),
                ),
              );
        } else {
          final prefs = await ref.read(prefsProvider.future);
          if (prefs.getBool(kStartupUnlockOptIn) == true) {
            await vault.forget();
            if (!await prefs.remove(kStartupUnlockOptIn)) {
              throw StateError('Consent not removed');
            }
          }
        }
        ref.invalidate(startupUnlockOptionsProvider);
      } catch (_) {
        if (mounted && ref.holdsIdentity(lease)) {
          setState(() {
            _busy = false;
            _error = l.startupUnlockSaveFailed;
          });
        }
        return;
      }
      if (!mounted || !ref.holdsIdentity(lease)) return;
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = l.quickUnlockSaveFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final available =
        ref.watch(localScreenAuthenticationAvailableProvider).asData?.value ??
        false;
    final startup = ref.watch(startupUnlockOptionsProvider).asData?.value;
    if (!_startupTouched && startup != null) _startup = startup.enabled;
    return SecureScreenGuard(
      child: Scaffold(
        appBar: AppBar(title: Text(l.quickUnlockTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l.quickUnlockHint),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _startup,
                  title: Text(l.startupUnlockTitle),
                  subtitle: Text(l.startupUnlockHint),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _startup = v;
                          _startupTouched = true;
                        }),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _grid ?? 0,
                  decoration: InputDecoration(labelText: l.quickUnlockPattern),
                  items: [
                    DropdownMenuItem(value: 0, child: Text(l.screenLockOff)),
                    for (final grid in [3, 4, 5])
                      DropdownMenuItem(
                        value: grid,
                        child: Text('$grid × $grid'),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _grid = value == 0 ? null : value;
                          _first = [];
                          _second = [];
                        }),
                ),
                if (_grid != null) ...[
                  const SizedBox(height: 12),
                  Text(l.quickUnlockDraw),
                  Center(
                    child: PatternPad(
                      key: ValueKey('setup-first-$_grid-$_padEpoch'),
                      grid: _grid!,
                      onChanged: (v) => _first = v,
                    ),
                  ),
                  Text(l.quickUnlockRepeat),
                  Center(
                    child: PatternPad(
                      key: ValueKey('setup-second-$_grid-$_padEpoch'),
                      grid: _grid!,
                      onChanged: (v) => _second = v,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            // A fresh subtree clears both entered sequences.
                            _first = [];
                            _second = [];
                            _padEpoch++;
                          }),
                    child: Text(l.quickUnlockReset),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.quickUnlockSystem),
                  subtitle: Text(
                    available
                        ? l.quickUnlockSystemHint
                        : l.quickUnlockUnavailable,
                  ),
                  value: _system,
                  onChanged: _busy || (!available && !_system)
                      ? null
                      : (v) => setState(() => _system = v),
                ),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: InputDecoration(labelText: l.lockPasswordHint),
                  onSubmitted: (_) => _save(),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy || startup == null ? null : _save,
                  child: Text(l.actionSave),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _padEpoch = 0;
}
