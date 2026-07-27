import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/async_error_view.dart';
import '../../domain/chat.dart';
import '../../domain/p2p_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/messaging.dart';

/// Batch editor for the "Only selected" P2P set: every accepted contact with
/// a toggle. On = a per-contact [ContactP2POverride.allow] (the same flag the
/// chat's communication settings set one at a time); off = follow the global
/// policy. Under the "selected" policy that override is what grants direct P2P,
/// so this screen is just a convenient roster view of it.
class P2PSelectedScreen extends ConsumerWidget {
  const P2PSelectedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final convos = ref.watch(conversationsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.p2pSelectedTitle),
      ),
      body: convos.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => AsyncErrorView(error: e, stack: st, where: 'p2p'),
        data: (list) {
          final accepted =
              [
                for (final c in list)
                  if (c.peer.status == ContactStatus.accepted) c.peer,
              ]..sort(
                (a, b) =>
                    a.label.toLowerCase().compareTo(b.label.toLowerCase()),
              );
          if (accepted.isEmpty) {
            return Center(child: Text(l.p2pSelectedEmpty));
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  l.p2pSelectedHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final peer in accepted)
                SwitchListTile(
                  secondary: CircleAvatar(
                    child: Text(peer.label.characters.first.toUpperCase()),
                  ),
                  title: Text(peer.label),
                  value: peer.p2pOverride == ContactP2POverride.allow,
                  onChanged: (on) => ref
                      .read(messagingServiceProvider)
                      .setContactP2POverride(
                        peer.nodeId,
                        on
                            ? ContactP2POverride.allow
                            : ContactP2POverride.followGlobal,
                      ),
                ),
            ],
          );
        },
      ),
    );
  }
}
