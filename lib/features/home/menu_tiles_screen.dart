import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../chat/chats_screen.dart';

/// A compact home for app-level actions that do not belong to a conversation.
///
/// The same actions remain available in the chats drawer. Keeping this tab
/// useful makes the bottom navigation honest on wide layouts and gives mobile
/// users a discoverable, one-tap alternative to opening the drawer first.
class MenuTilesScreen extends ConsumerWidget {
  const MenuTilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.navMenuTiles)),
      body: GridView.extent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 1.45,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          _MenuTile(
            icon: Icons.person_add_alt_1_outlined,
            label: l.inviteAddContact,
            onTap: () => showAddContactSheet(context, ref),
          ),
          _MenuTile(
            icon: Icons.diversity_3_outlined,
            label: l.navCommunities,
            onTap: () => context.push('/spaces'),
          ),
          _MenuTile(
            icon: Icons.call_outlined,
            label: l.navCalls,
            onTap: () => context.push('/calls'),
          ),
          _MenuTile(
            icon: Icons.cloud_outlined,
            label: l.navStorage,
            onTap: () => context.push('/storage'),
          ),
          _MenuTile(
            icon: Icons.hub_outlined,
            label: l.navNetwork,
            onTap: () => context.push('/network'),
          ),
          _MenuTile(
            icon: Icons.settings_outlined,
            label: l.navSettings,
            onTap: () => context.push('/settings'),
          ),
          _MenuTile(
            icon: Icons.lock,
            label: l.settingsLockNow,
            color: Theme.of(context).colorScheme.error,
            onTap: () => ref.read(appControllerProvider.notifier).lock(),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = color ?? scheme.onSurface;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color ?? scheme.primary, size: 30),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
