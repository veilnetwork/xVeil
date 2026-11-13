import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';
import '../../state/storage_router_providers.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_protection.dart';

/// Explicit identity management for a master: bind an existing identity into
/// this master, unbind one (keep its space), or delete one (forensically erase
/// it). Each operation re-enters the session, so the screen shows a busy overlay
/// while it works (the router keeps this screen mounted across that — see
/// router.dart). Master-mode only.
class ManageIdentitiesScreen extends ConsumerStatefulWidget {
  const ManageIdentitiesScreen({super.key});

  @override
  ConsumerState<ManageIdentitiesScreen> createState() =>
      _ManageIdentitiesScreenState();
}

class _ManageIdentitiesScreenState
    extends ConsumerState<ManageIdentitiesScreen> {
  bool _busy = false;

  Future<void> _run(Future<bool> Function() op, String failMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    bool ok = false;
    try {
      ok = await op();
    } catch (_) {
      // The controller recovers the session on a throw; here we just guarantee
      // the full-screen busy overlay is cleared (a swallowed throw would
      // otherwise skip the setState below and wedge the screen permanently).
      ok = false;
    }
    if (!mounted) return; // re-enter may have routed us to the picker
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failMessage)));
    }
  }

  Future<void> _toggleAnon(String label) async {
    final ctrl = ref.read(appControllerProvider.notifier);
    final next = !ctrl.isIdentityAnonymous(label);
    await _run(() => ctrl.setIdentityAnonymous(label, next), '');
  }

  Future<void> _unbind(String label) async {
    final l = AppL10n.of(context);
    final ok = await _confirm(
      title: l.manageUnbind,
      body: l.manageUnbindBody,
      confirm: l.manageUnbind,
      destructive: false,
    );
    if (ok != true) return;
    await _run(
      () => ref.read(appControllerProvider.notifier).unbindIdentity(label),
      l.manageUnbindLastError,
    );
  }

  Future<void> _delete(String label) async {
    final l = AppL10n.of(context);
    final ok = await _confirm(
      title: l.manageDelete,
      body: l.manageDeleteBody,
      confirm: l.manageDelete,
      destructive: true,
    );
    if (ok != true) return;
    await _run(
      () => ref.read(appControllerProvider.notifier).deleteIdentity(label),
      l.manageDeleteLastError,
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirm,
    required bool destructive,
  }) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: destructive
            ? Icon(Icons.warning_amber_rounded, color: scheme.error)
            : null,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _bind() async {
    final result =
        await showDialog<
          ({String password, String label, IdentityStorageLocator locator})
        >(context: context, builder: (ctx) => const _BindDialog());
    if (result == null) return;
    // The dialog above is an async gap — bail if this screen was disposed while
    // it was open, rather than touching a dead BuildContext.
    if (!mounted) return;
    final l = AppL10n.of(context);
    await _run(
      () => ref
          .read(appControllerProvider.notifier)
          .bindExistingIdentity(
            identityPassword: result.password,
            label: result.label,
            identityStorageLocator: result.locator,
          ),
      l.manageBindError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(appControllerProvider.notifier);
    final (identities, active) = ref.watch(
      appControllerProvider.select((s) => (s.identities, s.activeIdentity)),
    );

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.manageTitle),
      ),
      body: Stack(
        children: [
          ListView(
            children: [
              for (final label in identities)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(label.characters.first.toUpperCase()),
                  ),
                  title: Text(label),
                  subtitle: Row(
                    children: [
                      if (label == active)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            l.manageActive,
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                      if (ctrl.isIdentityAnonymous(label))
                        Text(
                          l.settingsAnonymousRouting,
                          style: TextStyle(color: scheme.primary),
                        ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'anon' => _toggleAnon(label),
                      'unbind' => _unbind(label),
                      'delete' => _delete(label),
                      _ => Future.value(),
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'anon',
                        child: Text(
                          ctrl.isIdentityAnonymous(label)
                              ? l.manageAnonOff
                              : l.manageAnonOn,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'unbind',
                        child: Text(l.manageUnbind),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          l.manageDelete,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(l.manageBind),
                subtitle: Text(l.manageBindHint),
                onTap: _busy ? null : _bind,
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks for an existing identity's own password + the name to list it under.
class _BindDialog extends ConsumerStatefulWidget {
  const _BindDialog();

  @override
  ConsumerState<_BindDialog> createState() => _BindDialogState();
}

class _BindDialogState extends ConsumerState<_BindDialog> {
  IdentityStorageLocator _locator = const LegacyStorageLocator();
  final _password = TextEditingController();
  final _label = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    ref.watch(storageRouteRevisionProvider);
    final router = ref.watch(profileStorageRouterProvider);
    final locator = _locator;
    final access = router?.access;
    final plainMaster =
        access is ManagedStorageLocator &&
        access.protection == StorageProtection.unencrypted;
    final unencrypted =
        locator is ManagedStorageLocator &&
        locator.protection == StorageProtection.unencrypted;
    return AlertDialog(
      title: Text(l.manageBind),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.manageBindBody, style: Theme.of(context).textTheme.bodySmall),
          if (plainMaster)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                l.storagePlainMasterWarning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          if (router != null) ...[
            DropdownButtonFormField<IdentityStorageLocator>(
              initialValue: _locator,
              isExpanded: true,
              decoration: InputDecoration(labelText: l.storageChooseIdentity),
              items: [
                DropdownMenuItem(
                  value: const LegacyStorageLocator(),
                  child: Text(l.storageHiddenTitle),
                ),
                for (final entry in router.catalog.identities)
                  DropdownMenuItem(
                    value: entry.locator,
                    child: Text(
                      '${entry.protection == StorageProtection.encrypted ? l.storageEncryptedTitle : l.storageUnencryptedTitle} · ${entry.id.value.substring(0, 8)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                _password.clear();
                setState(() => _locator = value);
              },
            ),
            const SizedBox(height: 12),
          ],
          if (!unencrypted)
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.manageBindPassword,
                border: const OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _label,
            decoration: InputDecoration(
              labelText: l.manageBindLabel,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final pw = unencrypted ? '' : _password.text;
            final label = _label.text.trim();
            if ((!unencrypted && pw.isEmpty) || label.isEmpty) return;
            Navigator.of(
              context,
            ).pop((password: pw, label: label, locator: _locator));
          },
          child: Text(l.manageBind),
        ),
      ],
    );
  }
}
