// The Channels tab (nav redesign NAV1). Group CHATS moved into the chats
// list — ideologically channels are a different thing (owner-signed broadcast
// feeds, the future Ф3 epic) — so until that epic lands this is an honest
// empty surface that already behaves like a real tab: same list styling as
// Chats, its own AppBar, the bottom bar highlights it.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class ChannelsScreen extends StatelessWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l.navChannels)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(l.channelsEmpty,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                l.channelsEmptyHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
