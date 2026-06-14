import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/transport/bootstrap_invite.dart';

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
      setState(() => _error = 'That is not a valid xVeil invite');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add a contact',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (widget.myInvite != null) ...[
            Text('Show this to your contact',
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
                  errorStateBuilder: (_, _) => const SizedBox(
                    width: 180,
                    height: 180,
                    child: Center(child: Text('invite too large')),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: widget.myInvite!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy my invite'),
              ),
            ),
            const Divider(height: 32),
          ],
          Text('Paste their invite',
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
                tooltip: 'Scan QR (coming soon)',
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Camera scanning coming soon')),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _add,
            style: FilledButton.styleFrom(backgroundColor: scheme.primary),
            child: const Text('Add contact'),
          ),
        ],
      ),
    );
  }
}
