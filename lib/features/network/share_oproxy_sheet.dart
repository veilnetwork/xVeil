import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/node/proxy_routing.dart';
import '../../domain/chat.dart';
import '../../data/transport/oproxy_invite.dart';
import '../../l10n/app_localizations.dart';
import '../common/shown_cause.dart';
import '../../state/messaging_providers.dart';

/// Hand ONE exit to somebody: the link, a QR of it, and the contact list.
///
/// The server half of sharing a proxy is the allowlist — the operator admits a
/// node id and that node may route through the exit. This is the other half,
/// and without it the only way to tell someone WHICH node to point at was to
/// read sixty-four hex characters out over another channel.
///
/// The link carries the node id and a name and nothing else: no identity of the
/// sharer, no credentials, nothing dialable.
class ShareOproxySheet extends ConsumerWidget {
  const ShareOproxySheet({super.key, required this.endpoint});

  final OproxyEndpoint endpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final uri = OproxyInvite(
      nodeId: endpoint.nodeId,
      label: endpoint.label,
    ).toUri();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.oproxyShareTitle(endpoint.label),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            // Admission is a SEPARATE decision on the server. Sending the link
            // to someone who is not on the allowlist gives them something that
            // will refuse them, so say so where the link is handed over.
            Text(l.oproxyShareAdmissionHint),
            const SizedBox(height: 12),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: uri, size: 180),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              uri,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: uri));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.chatLinkCopied)),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(l.linkCopy),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _sendToContact(context, ref, uri),
                    icon: const Icon(Icons.send),
                    label: Text(l.oproxyShareSend),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendToContact(
    BuildContext context,
    WidgetRef ref,
    String uri,
  ) async {
    final l = AppL10n.of(context);
    final conversations =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    // Blocked contacts are not offered: handing an exit to someone who has been
    // shut out is not a thing to do by accident.
    final contacts = conversations
        .map((c) => c.peer)
        .where((c) => c.status != ContactStatus.blocked)
        .toList();
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.oproxyShareNoContacts)));
      return;
    }
    final chosen = await showModalBottomSheet<Contact>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                l.oproxyShareSend,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            for (final contact in contacts)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(contact.name ?? contact.nodeId.hex.substring(0, 8)),
                subtitle: Text(
                  contact.nodeId.hex,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                onTap: () => Navigator.of(sheet).pop(contact),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    try {
      await ref
          .read(messagingServiceProvider)
          .sendText(chosen.nodeId, uri);
    } catch (error) {
      if (!context.mounted) return;
      // Through shownCause, never raw: a send failure quotes node ids, and a
      // snackbar carrying one goes into whatever screenshot the person sends
      // while asking for help.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(shownCause(error, kind: 'oproxy-share'))),
      );
      return;
    }
    if (!context.mounted) return;
    // The messenger is taken BEFORE the sheet closes. Looking it up through a
    // context that `pop` has just removed is how a confirmation ends up thrown
    // away — or throwing — at the one moment the person needs to see it.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l.oproxyShareSent(chosen.name ?? chosen.nodeId.hex.substring(0, 8)),
        ),
      ),
    );
  }
}
