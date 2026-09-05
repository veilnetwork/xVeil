import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';

/// One answerable question, and its answer.
class HelpTopic {
  const HelpTopic({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;
}

/// What the app is and how to use it, for somebody who has never met one.
///
/// The audience is deliberately not a technical one. Nothing here explains a
/// protocol, a transport or a key: those are true, and they are not what a
/// person opening this wants to know. What they want is why nobody asked for
/// their phone number, why it sometimes says nobody was found, and what the
/// words on the buttons mean.
///
/// The text lives in the ARB files like every other string, so it is
/// translated the same way and cannot drift into English on a Russian phone.
List<HelpTopic> helpTopics(AppL10n l) => [
  HelpTopic(
    icon: Icons.waving_hand_outlined,
    title: l.helpWhatTitle,
    body: l.helpWhatBody,
  ),
  HelpTopic(
    icon: Icons.badge_outlined,
    title: l.helpIdentityTitle,
    body: l.helpIdentityBody,
  ),
  HelpTopic(
    icon: Icons.person_add_alt_1_outlined,
    title: l.helpContactsTitle,
    body: l.helpContactsBody,
  ),
  HelpTopic(
    icon: Icons.wifi_tethering_off,
    title: l.helpOfflineTitle,
    body: l.helpOfflineBody,
  ),
  HelpTopic(
    icon: Icons.call_outlined,
    title: l.helpCallsTitle,
    body: l.helpCallsBody,
  ),
  HelpTopic(
    icon: Icons.folder_shared_outlined,
    title: l.helpFilesTitle,
    body: l.helpFilesBody,
  ),
  HelpTopic(
    icon: Icons.groups_outlined,
    title: l.helpIdentitiesTitle,
    body: l.helpIdentitiesBody,
  ),
  HelpTopic(
    icon: Icons.shield_moon_outlined,
    title: l.helpPrivacyTitle,
    body: l.helpPrivacyBody,
  ),
  HelpTopic(
    icon: Icons.lock_outline,
    title: l.helpLossTitle,
    body: l.helpLossBody,
  ),
  HelpTopic(
    icon: Icons.help_outline,
    title: l.helpStuckTitle,
    body: l.helpStuckBody,
  ),
];

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final topics = helpTopics(l);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.navHelp),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              l.helpIntro,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          for (final t in topics)
            ExpansionTile(
              leading: Icon(t.icon),
              title: Text(t.title),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.body, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: Text(l.navNetwork),
            subtitle: Text(l.helpGoNetwork),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/network'),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(l.navSettings),
            subtitle: Text(l.helpGoSettings),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),
        ],
      ),
    );
  }
}
