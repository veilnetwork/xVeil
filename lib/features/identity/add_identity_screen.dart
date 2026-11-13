import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';
import '../../state/storage_router_providers.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_protection.dart';
import '../common/help_label.dart';

/// Form to add a new identity. On the FIRST add (single-identity mode) it also
/// converts the current space into a master, so it asks for a master password
/// and a label for the existing identity. Thereafter it just appends.
class AddIdentityScreen extends ConsumerStatefulWidget {
  const AddIdentityScreen({super.key});

  @override
  ConsumerState<AddIdentityScreen> createState() => _AddIdentityScreenState();
}

class _AddIdentityScreenState extends ConsumerState<AddIdentityScreen> {
  final _newName = TextEditingController();
  final _newPassword = TextEditingController();
  final _masterPassword = TextEditingController();
  final _currentName = TextEditingController();
  bool _busy = false;
  StorageProtection _protection = StorageProtection.defaultForNewIdentity;
  StorageProtection _masterProtection = StorageProtection.defaultForNewIdentity;

  StorageProtection _effectiveMasterMode(bool converting) {
    if (converting) return _masterProtection;
    return switch (ref.read(profileStorageRouterProvider)?.access) {
      ManagedStorageLocator(:final protection) => protection,
      _ => StorageProtection.hidden,
    };
  }

  // Default OFF, matching a single identity's default (direct routing, no onion
  // overhead). The user opts INTO anonymity per-identity when they want it.
  bool _anonymous = false;
  String? _error;

  @override
  void dispose() {
    _newName.dispose();
    _newPassword.dispose();
    _masterPassword.dispose();
    _currentName.dispose();
    super.dispose();
  }

  Future<void> _submit(bool converting) async {
    final l = AppL10n.of(context);
    if (_busy) return;
    final routed = ref.read(profileStorageRouterProvider) != null;
    final plainChild = routed && _protection == StorageProtection.unencrypted;
    final plainMaster =
        routed &&
        _effectiveMasterMode(converting) == StorageProtection.unencrypted;
    if (_newName.text.trim().isEmpty ||
        (!plainChild && _newPassword.text.isEmpty) ||
        (!plainMaster && _masterPassword.text.isEmpty)) {
      setState(() => _error = l.addIdentityIncomplete);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    bool ok = false;
    try {
      ok = await ref
          .read(appControllerProvider.notifier)
          .addIdentity(
            masterPassword: plainMaster ? '' : _masterPassword.text,
            label: _newName.text.trim(),
            password: plainChild ? '' : _newPassword.text,
            protection: routed ? _protection : null,
            masterProtection: routed && converting ? _masterProtection : null,
            existingLabel: converting && _currentName.text.trim().isNotEmpty
                ? _currentName.text.trim()
                : 'Identity 1',
            anonymous: _anonymous,
          );
    } catch (_) {
      // Never leave the form stuck on the busy spinner if the FFI op throws —
      // surface it as a clash/failure so the user can retry.
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      // Now in the new identity's session — go home (the phase is already
      // ready/preparing; go() keeps the router consistent vs a manual pop).
      context.go('/home');
    } else {
      setState(() {
        _busy = false;
        _error = l.addIdentityClash;
      });
    }
  }

  Widget _modeChoice(
    String title,
    StorageProtection value,
    ValueChanged<StorageProtection> onChanged,
  ) {
    final l = AppL10n.of(context);
    return DropdownButtonFormField<StorageProtection>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: title,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final (mode, text) in [
          (StorageProtection.encrypted, l.storageEncryptedTitle),
          (StorageProtection.hidden, l.storageHiddenTitle),
          (StorageProtection.unencrypted, l.storageUnencryptedTitle),
        ])
          DropdownMenuItem(
            value: mode,
            child: Text(text, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _busy
          ? null
          : (mode) {
              if (mode != null) onChanged(mode);
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final converting = !ref.watch(appControllerProvider).isMaster;
    ref.watch(storageRouteRevisionProvider);
    final routed = ref.watch(profileStorageRouterProvider) != null;
    final plainChild = routed && _protection == StorageProtection.unencrypted;
    final plainMaster =
        routed &&
        _effectiveMasterMode(converting) == StorageProtection.unencrypted;

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.addIdentityTitle),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  l.addIdentitySubtitle,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                if (converting) ...[
                  TextField(
                    controller: _currentName,
                    decoration: InputDecoration(
                      labelText: l.addIdentityCurrentName,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _newName,
                  decoration: InputDecoration(
                    labelText: l.addIdentityNewName,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                if (routed) ...[
                  _modeChoice(l.storageNewIdentityMode, _protection, (mode) {
                    _newPassword.clear();
                    setState(() => _protection = mode);
                  }),
                  const SizedBox(height: 16),
                  if (plainChild)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        l.storageUnencryptedWarning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
                if (!plainChild)
                  TextField(
                    controller: _newPassword,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.addIdentityNewPassword,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 16),
                if (routed && converting) ...[
                  _modeChoice(l.storageNewMasterMode, _masterProtection, (
                    mode,
                  ) {
                    _masterPassword.clear();
                    setState(() => _masterProtection = mode);
                  }),
                  const SizedBox(height: 16),
                ],
                if (plainMaster)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      l.storagePlainMasterWarning,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (!plainMaster)
                  TextField(
                    controller: _masterPassword,
                    obscureText: true,
                    decoration: InputDecoration(
                      label: HelpLabel(
                        title: l.addIdentityMasterPassword,
                        help: l.addIdentityMasterHint,
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _anonymous,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _anonymous = v),
                  title: Text(l.addIdentityAnonymous),
                  subtitle: Text(l.addIdentityAnonymousHint),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : () => _submit(converting),
                  child: Text(l.addIdentityCreate),
                ),
              ],
            ),
          ),
          // Argon2 container opens block the platform thread for a moment; show
          // an intentional "working" overlay so it doesn't read as a freeze.
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            l.addIdentityWorking,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
