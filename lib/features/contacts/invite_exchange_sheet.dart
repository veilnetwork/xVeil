import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/transport/bootstrap_invite.dart';
import '../../l10n/app_localizations.dart';

/// Contact-add UX over veil bootstrap invites. Shows THIS device's invite as a
/// QR to share, and accepts a peer's invite (pasted; camera scan plugs in
/// later). Both directions are needed: each device shares its invite and
/// redeems the other's, which forms the bidirectional session veil requires.
///
/// Deliberately decoupled from the node: [myInvite] is supplied by the caller
/// and [onAddContact] fires with the parsed peer invite — so the whole flow is
/// widget-testable without a running node.
class InviteExchangeSheet extends StatefulWidget {
  const InviteExchangeSheet({
    super.key,
    required this.myInvite,
    required this.onAddContact,
  });

  /// This device's `veil:bootstrap?…` URI, or null while the node is starting.
  final String? myInvite;

  final void Function(BootstrapInvite invite) onAddContact;

  @override
  State<InviteExchangeSheet> createState() => _InviteExchangeSheetState();
}

class _InviteExchangeSheetState extends State<InviteExchangeSheet> {
  final _paste = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _add() {
    final text = _paste.text.trim();
    try {
      final invite = BootstrapInvite.parse(text);
      setState(() => _error = null);
      widget.onAddContact(invite);
    } on FormatException {
      setState(() => _error = AppL10n.of(context).inviteInvalid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.inviteAddContact,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (widget.myInvite != null) ...[
            Text(l.inviteShowToContact,
                style: Theme.of(context).textTheme.labelMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: widget.myInvite!,
                  size: 180,
                  // Errors (e.g. data too long) render inline, never throw.
                  errorStateBuilder: (_, _) => SizedBox(
                    width: 180,
                    height: 180,
                    child: Center(child: Text(l.inviteTooLarge)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // The raw link, so it works on desktop (no camera) — selectable +
            // copyable.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.myInvite!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: widget.myInvite!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.inviteCopied)),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l.inviteCopyMine),
              ),
            ),
            const Divider(height: 32),
          ],
          Text(l.invitePasteTheirs,
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _paste,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'veil:bootstrap?…',
              errorText: _error,
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: l.inviteScanTooltip,
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.inviteScanComingSoon)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _add,
            style: FilledButton.styleFrom(backgroundColor: scheme.primary),
            child: Text(l.inviteAddButton),
          ),
        ],
        ),
      ),
    );
  }
}
