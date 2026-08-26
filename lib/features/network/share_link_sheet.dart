import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../common/shown_cause.dart';
import '../../state/messaging_providers.dart';

/// Hand a link to somebody: the link, a QR of it, and the contact list.
///
/// The server half of sharing a proxy is the allowlist — the operator admits a
/// node id and that node may route through the exit. This is the other half,
/// and without it the only way to tell someone WHICH node to point at was to
/// read sixty-four hex characters out over another channel.
///
/// The link carries the node id and a name and nothing else: no identity of the
/// sharer, no credentials, nothing dialable.
class ShareLinkSheet extends ConsumerStatefulWidget {
  const ShareLinkSheet({
    super.key,
    required this.title,
    required this.hint,
    required this.uri,
  });

  /// What is being handed over, named.
  final String title;

  /// What the recipient should know before they act on it. Different per link:
  /// an exit says admission is decided on the server, an entry point says what
  /// it does and does not carry.
  final String hint;

  /// The link itself. Built by the caller so this widget never has to know
  /// which kind it is showing.
  final String uri;

  @override
  ConsumerState<ShareLinkSheet> createState() => _ShareLinkSheetState();
}

class _ShareLinkSheetState extends ConsumerState<ShareLinkSheet> {
  /// Anything this sheet has to SAY, said inside the sheet.
  ///
  /// A snackbar from here is posted to the ScaffoldMessenger under the modal
  /// route, so the sheet covers it: measured on a phone, pressing "send to a
  /// contact" with no contacts produced nothing visible at all. A button that
  /// answers in a place the person cannot see has not answered.
  String? _notice;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final uri = widget.uri;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            // Admission is a SEPARATE decision on the server. Sending the link
            // to someone who is not on the allowlist gives them something that
            // will refuse them, so say so where the link is handed over.
            Text(widget.hint),
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
            if (_notice != null) ...[
              Text(
                _notice!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
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
                    onPressed: () => _sendToContact(uri),
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

  Future<void> _sendToContact(String uri) async {
    final l = AppL10n.of(context);
    setState(() => _notice = null);
    final conversations =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    // ACCEPTED only, not merely "not blocked".
    //
    // `sendText` has a consent gate and returns silently for anything else, so
    // offering a pending contact meant choosing them, watching the sheet close,
    // and being told it was sent — when nothing had been (report16 XV-17).
    // Handing an exit to somebody who has been shut out is not a thing to do by
    // accident either, and this covers that too.
    final contacts = conversations
        .map((c) => c.peer)
        .where((c) => c.status == ContactStatus.accepted)
        .toList();
    if (contacts.isEmpty) {
      setState(() => _notice = l.oproxyShareNoContacts);
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
    if (chosen == null || !mounted) return;
    // Asked again, from the list as it stands NOW. The picker was built before
    // it was shown, and a contact can be un-accepted while it is open — after
    // which the send is a silent no-op and this would still say it went.
    final current = (ref.read(conversationsProvider).value ?? const <Conversation>[])
        .map((c) => c.peer)
        .where((c) => c.nodeId == chosen.nodeId)
        .firstOrNull;
    if (current == null || current.status != ContactStatus.accepted) {
      setState(() => _notice = l.oproxyShareNotAccepted);
      return;
    }
    try {
      await ref
          .read(messagingServiceProvider)
          .sendText(chosen.nodeId, uri);
    } catch (error) {
      if (!mounted) return;
      // Through shownCause, never raw: a send failure quotes node ids, and a
      // message carrying one goes into whatever screenshot the person sends
      // while asking for help. In the sheet, not a snackbar — see [_notice].
      setState(() => _notice = shownCause(error, kind: 'oproxy-share'));
      return;
    }
    if (!mounted) return;
    // The messenger is taken BEFORE the sheet closes, and this ONE message is a
    // snackbar rather than a [_notice]: the sheet is about to go away, so there
    // is nowhere in it left to read. Looking the messenger up through a context
    // that `pop` has just removed is how a confirmation ends up thrown away — or
    // throwing — at the one moment the person needs to see it.
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
