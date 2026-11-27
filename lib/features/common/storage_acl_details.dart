import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/storage/managed_fs_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../state/storage_router_providers.dart';

class AcceptedAccessWarningButton extends ConsumerWidget {
  const AcceptedAccessWarningButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warnings = ref.watch(startupAcceptedAccessWarningsProvider);
    if (warnings.isEmpty) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    return IconButton(
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
      tooltip: l.startupAcceptedAccessTitle,
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.startupAcceptedAccessTitle),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final warning in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: StorageAclDetails(warning),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class StorageAclDetails extends StatelessWidget {
  const StorageAclDetails(this.warning, {super.key});

  final ManagedStorageAclWarning warning;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(warning.path),
        const SizedBox(height: 8),
        if (warning.owner case final owner?) Text(l.startupAclOwner(owner)),
        if (warning.grantsArePotential && warning.grants.isNotEmpty)
          Text(l.storageAclPotentialGrants),
        if (warning.readOnlyInApp) Text(l.storageAclSettingsReadOnly),
        for (final grant in warning.grants)
          Text(
            l.startupAclGrant(
              grant.account.isEmpty ? l.startupAclEveryone : grant.account,
              grant.rights.map((right) => _rightLabel(l, right)).join(', '),
            ),
          ),
        if (warning.inheritedGrants.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l.storageAclInheritedGrants),
          if (warning.inheritedScopes.isEmpty)
            for (final grant in warning.inheritedGrants)
              Text(
                l.startupAclGrant(
                  grant.account.isEmpty ? l.startupAclEveryone : grant.account,
                  grant.rights.map((right) => _rightLabel(l, right)).join(', '),
                ),
              ),
          for (final scope in warning.inheritedScopes)
            Text(
              l.startupAclGrant(
                scope.account,
                '${scope.rights.map((right) => _rightLabel(l, right)).join(', ')} · '
                '${switch ((scope.files, scope.directories)) {
                  (true, true) => l.storageAclInheritedFilesAndFolders,
                  (true, false) => l.storageAclInheritedFiles,
                  _ => l.storageAclInheritedFolders,
                }}'
                '${scope.directChildrenOnly ? ' · ${l.storageAclDirectChildrenOnly}' : ''}',
              ),
            ),
        ],
        if (warning.extendedAcl case final acl?)
          ExpansionTile(
            title: Text(l.startupAclDetails),
            initiallyExpanded:
                warning.grants.isEmpty && warning.inheritedGrants.isEmpty,
            children: [SelectableText(acl)],
          ),
      ],
    );
  }
}

String _rightLabel(AppL10n l, ManagedAclRight right) => switch (right) {
  ManagedAclRight.read => l.startupAclRead,
  ManagedAclRight.write => l.startupAclWrite,
  ManagedAclRight.execute => l.startupAclExecute,
  ManagedAclRight.delete => l.startupAclDelete,
  ManagedAclRight.deleteChildren => l.startupAclDeleteChildren,
  ManagedAclRight.changePermissions => l.startupAclChangePermissions,
  ManagedAclRight.changeOwner => l.startupAclChangeOwner,
  ManagedAclRight.fullControl => l.startupAclFullControl,
  ManagedAclRight.other => l.startupAclOther,
};
